#!/usr/bin/env bash
# start.sh [feature-branch] — make this Rex pane the repo's coordinator.
# The feature branch is whatever the main checkout has checked out. Without an
# argument that is the current branch; with one, it checks that branch out in
# the main checkout first, and refuses unless the checkout is clean.
# Run in a folder that is not a git repo but has git repos as direct children,
# it starts workspace mode instead (no argument): one coordinator for them all.
# Either way it refuses while another live coordinator covers the same repo.
# --land pr|merge|auto: how new tasks land by default (state's land=; auto,
# the default: a PR when the task's base is the repo's default branch and
# origin is on GitHub or Azure DevOps, else a local merge). new-task.sh --land overrides it.
source "$(dirname "$0")/lib.sh"
land=auto args=()
while [ $# -gt 0 ]; do
  case $1 in
    --land) [ $# -ge 2 ] || die "--land needs pr, merge or auto"; land=$2; shift 2 ;;
    --land=*) land=${1#--land=}; shift ;;
    -*) die "usage: start.sh [feature-branch] [--land pr|merge|auto] (got '$1')" ;;
    *) args+=("$1"); shift ;;
  esac
done
case $land in pr|merge|auto) ;; *) die "--land takes pr, merge or auto (got '$land')" ;; esac
[ ${#args[@]} -le 1 ] || die "usage: start.sh [feature-branch] [--land pr|merge|auto]"
set -- ${args[@]+"${args[@]}"}
[ "${CLAUDE_ROLE:-}" != worker ] || die "CLAUDE_ROLE=worker: a worker can't become the coordinator"
[ -n "${REX_BLOCK:-}" ] || die "REX_BLOCK is not set: run this inside a Rex pane"
[ -n "${REX_SESSION:-}" ] || die "REX_SESSION is not set"
bash "$(dirname "$0")/doctor.sh" --quiet \
  || die "required tools are missing (above): install or update them (tsk: 'tsk update', or https://gettsk.sh), then rerun /coordinator-start"

# Mode: in a git repo, single-repo mode for its main checkout (as always).
# In a folder that is not a git repo but has git repos as direct children,
# workspace mode: one coordinator for all of them, state keyed by the folder.
if git rev-parse --git-common-dir >/dev/null 2>&1; then mode=single; else mode=workspace; fi

# coexist_check <what> <session> <block>: refuse while that other coordinator's
# pane is still open; once it is gone, allow with a note.
coexist_check() {
  if rex_block_alive "$2" "$3"; then
    die "$1 has a live coordinator in Rex block $3$( [ "$3" != "$REX_BLOCK" ] || echo ' (this pane)'): run stop.sh there first (or close that pane), then rerun /coordinator-start"
  fi
  echo "Note: $1 had a coordinator in Rex block $3, which is gone: taking over." >&2
}

if [ $mode = single ]; then
  root=$(repo_root)
  dir=$(repo_state_dir)
  # A live workspace coordinator over the folder holding this repo covers it.
  wsd=$(ws_state_walk "$(dirname "$root")")
  if [ -n "$wsd" ]; then
    wsr=$(sed -n 's/^root=//p' "$wsd/state" | head -n1)
    if [ "$wsr" = "$(canon_dir "$(dirname "$root")")" ] || [ "$wsr" = "$(dirname "$root")" ]; then
      coexist_check "the workspace $wsr (holding this repo)" \
        "$(sed -n 's/^session=//p' "$wsd/state" | head -n1)" "$(sed -n 's/^block=//p' "$wsd/state" | head -n1)"
    fi
  fi
  _STATE_DIR=$dir
  cur=$(git -C "$root" branch --show-current)
  feature=${1:-$cur}
  [ -n "$feature" ] || die "main checkout is on a detached HEAD; check out the feature branch, or pass it"
  git -C "$root" rev-parse --verify -q "refs/heads/$feature" >/dev/null || die "no local branch '$feature'"
  if [ "$feature" != "$cur" ]; then
    [ -z "$(checkout_busy "$root")" ] \
      || die "the main checkout ($root) has a merge, rebase or cherry-pick in progress: finish it before switching to '$feature'"
    ! checkout_dirty "$root" \
      || die "the main checkout ($root) has uncommitted changes: commit or stash them before switching to '$feature' (or run /coordinator-start without a branch to stay on ${cur:-the current HEAD})"
    git -C "$root" checkout -q "$feature" || die "could not check out '$feature' in $root"
    echo "Checked out $feature in the main checkout (was ${cur:-detached})."
  fi
else
  [ $# -eq 0 ] || die "workspace mode takes no branch argument: check a branch out in the repo itself (git -C <repo> checkout <branch>)"
  root=$(pwd -P)
  repos=$(ws_repos "$root")
  [ -n "$repos" ] || die "not inside a git repository, and $root has no git repos directly under it"
  dir=$(state_path_for_dir "$root")
  # A member repo with its own live coordinator stays with it.
  for r in $repos; do
    c=$(git -C "$root/$r" rev-parse --path-format=absolute --git-common-dir 2>/dev/null) || continue
    for sd in "$(state_path_for "$c")" "$(state_legacy_dir "$c")"; do
      [ -f "$sd/state" ] || continue
      ob=$(sed -n 's/^block=//p' "$sd/state" | head -n1)
      [ -n "$ob" ] && coexist_check "the repo $r" "$(sed -n 's/^session=//p' "$sd/state" | head -n1)" "$ob"
      break
    done
  done
  _STATE_DIR=$dir
fi

old=$(state_get block || true)
old_session=$(state_get session || true)
old_tsk=$(state_get tsk_block || true)
old_tsk_layer=$(state_get tsk_layer || true)
old_win=$(state_get tab_window || true)
old_label=$(state_get tab_label || true)
if [ $mode = single ]; then
  # Open tasks without a .base were cut from the last recorded feature branch:
  # pin that before it is overwritten.
  last=$(state_get feature || true)
  if [ -n "$last" ] && [ "$last" != "$feature" ]; then
    mkdir -p "$dir/tasks"
    for s in $(open_task_slugs); do [ -s "$dir/tasks/$s.base" ] || echo "$last" > "$dir/tasks/$s.base"; done
  fi
  mkdir -p "$dir"/{briefs,reports,research,tasks}
  cat > "$dir/state" <<STATE
block=$REX_BLOCK
session=$REX_SESSION
feature=$feature
land=$land
started=$(date -u +%Y-%m-%dT%H:%M:%SZ)
STATE

  # Keep worktrees out of git status without touching .gitignore.
  exclude="$(git rev-parse --path-format=absolute --git-common-dir)/info/exclude"
  mkdir -p "$(dirname "$exclude")"
  grep -qxF '.claude/worktrees/' "$exclude" 2>/dev/null || echo '.claude/worktrees/' >> "$exclude"
else
  mkdir -p "$dir"/{briefs,reports,research,tasks}
  {
    echo "block=$REX_BLOCK"
    echo "session=$REX_SESSION"
    echo "mode=workspace"
    echo "root=$root"
    echo "land=$land"
    for r in $repos; do
      b=$(checkout_branch "$root/$r")
      [ -z "$b" ] || echo "feature.$r=$b"
    done
    echo "started=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  } > "$dir/state.tmp.$$" && mv -f "$dir/state.tmp.$$" "$dir/state"
fi

# Rex layout, best-effort: name this tab "coordinator" and keep one tsk board
# pane beside this pane (labelled "tsk", so tsk's own alt+t focuses it). A
# rerun reuses the recorded pane while it is still in this tab; focus stays here.
win=$(rex_block_window "$REX_SESSION" "$REX_BLOCK")
if [ -z "$win" ]; then
  rex_warn "could not find this pane's tab in Rex: tab not renamed, no tsk pane"
else
  if [ "$win" = "$old_win" ] && [ -n "$old_label" ]; then
    label=$old_label # renamed by an earlier run: keep the tab's own name for stop.sh
  else
    [ -z "$old_win" ] || rex_restore_tab "$old_session" "$old_win" "$old_label"
    label=$(rex_window_label "$REX_SESSION" "$win")
  fi
  if rex window rename -s "$REX_SESSION" "$win" coordinator >/dev/null 2>&1; then
    state_set tab_window "$win"
    [ -z "$label" ] || [ "$label" = coordinator ] || state_set tab_label "$label"
  else
    rex_warn "could not rename this tab to 'coordinator'"
  fi
  tb="" tl=""
  if [ -n "$old_tsk" ]; then
    # Reuse the board while it is in this tab, as the user left it (open or
    # minimized). An older version's split board is replaced by a floating one.
    if [ "$(rex_block_window "$old_session" "$old_tsk")" = "$win" ]; then
      read -r tl tsk_kind _ <<<"$(rex_block_layer "$old_session" "$old_tsk")" || true
      if [ "${tsk_kind:-}" = floating ] || ! rex_has_layers; then
        tb=$old_tsk
        [ "${tsk_kind:-}" = floating ] || tl=""
      else
        tl=""
      fi
    fi
    [ -n "$tb" ] || rex_close_board "$old_session" "$old_tsk" "$old_tsk_layer"
  fi
  if [ -z "$tb" ]; then
    if tsk_bin=$(command -v tsk); then
      read -r tb tl <<<"$(rex_open_board "$REX_SESSION" "$win" "$REX_BLOCK" "$root" "$tsk_bin")" || true
      [ -n "$tb" ] || rex_warn "could not open the tsk board pane"
    else
      echo "Note: tsk not found, so no tsk board pane." >&2
    fi
  fi
  [ -z "$tb" ] || state_set tsk_block "$tb"
  [ -z "$tl" ] || state_set tsk_layer "$tl"
fi

[ -n "$old" ] && [ "$old" != "$REX_BLOCK" ] && echo "Replaced previous coordinator $old."
echo "Coordinator: $REX_BLOCK"
if [ $mode = single ]; then
  echo "Feature branch: $feature ($(git -C "$root" rev-parse --short "$feature"))"
else
  echo "Workspace: $root ($(echo "$repos" | wc -l | tr -d ' ') repos; each repo's feature branch is the branch its checkout has)"
  for r in $repos; do
    b=$(git -C "$root/$r" branch --show-current 2>/dev/null) || b=
    sha=$(git -C "$root/$r" rev-parse -q --verify --short HEAD 2>/dev/null) || sha="no commits"
    echo "$r: ${b:-detached HEAD} @ $sha"
  done
fi
echo "State: $dir"
case $land in
  auto) echo "Landing: by base (a PR when a task's base is the repo's default branch and origin is on GitHub or Azure DevOps, else a local merge)" ;;
  *) echo "Landing: $land for every new task (new-task.sh --land overrides)" ;;
esac
[ -z "${tb:-}" ] || echo "tsk board pane: $tb${tl:+ (floating, layer $tl)}"
