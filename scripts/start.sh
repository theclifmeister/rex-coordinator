#!/usr/bin/env bash
# start.sh [feature-branch] — make this Rex pane the repo's coordinator.
# The feature branch is whatever the main checkout has checked out. Without an
# argument that is the current branch; with one, it checks that branch out in
# the main checkout first, and refuses unless the checkout is clean.
source "$(dirname "$0")/lib.sh"
[ "${CLAUDE_ROLE:-}" != worker ] || die "CLAUDE_ROLE=worker: a worker can't become the coordinator"
[ -n "${REX_BLOCK:-}" ] || die "REX_BLOCK is not set: run this inside a Rex pane"
[ -n "${REX_SESSION:-}" ] || die "REX_SESSION is not set"
bash "$(dirname "$0")/doctor.sh" --quiet \
  || die "required tools are missing (above): install or update them (tsk: 'tsk update', or https://gettsk.sh), then rerun /coordinator-start"

dir=$(state_dir)
root=$(repo_root)
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

old=$(state_get block || true)
old_session=$(state_get session || true)
old_tsk=$(state_get tsk_block || true)
old_win=$(state_get tab_window || true)
old_label=$(state_get tab_label || true)
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
started=$(date -u +%Y-%m-%dT%H:%M:%SZ)
STATE

# Keep worktrees out of git status without touching .gitignore.
exclude="$(git rev-parse --path-format=absolute --git-common-dir)/info/exclude"
mkdir -p "$(dirname "$exclude")"
grep -qxF '.claude/worktrees/' "$exclude" 2>/dev/null || echo '.claude/worktrees/' >> "$exclude"

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
  tb=""
  if [ -n "$old_tsk" ]; then
    if [ "$(rex_block_window "$old_session" "$old_tsk")" = "$win" ]; then
      tb=$old_tsk
    else
      rex_close_board "$old_session" "$old_tsk" # beside an earlier coordinator pane
    fi
  fi
  if [ -z "$tb" ]; then
    if tsk_bin=$(command -v tsk); then
      tb=$(rex split -s "$REX_SESSION" -b "$REX_BLOCK" --split=right --ratio 40 --focus=false \
             --label tsk -c "$root" --json -- "$tsk_bin" 2>/dev/null \
           | jq -r '.block_ids[0] // empty' 2>/dev/null) || tb=""
      [ -n "$tb" ] || rex_warn "could not open the tsk board pane beside this pane"
    else
      echo "Note: tsk not found, so no tsk board pane." >&2
    fi
  fi
  [ -z "$tb" ] || state_set tsk_block "$tb"
fi

[ -n "$old" ] && [ "$old" != "$REX_BLOCK" ] && echo "Replaced previous coordinator $old."
echo "Coordinator: $REX_BLOCK"
echo "Feature branch: $feature ($(git -C "$root" rev-parse --short "$feature"))"
echo "State: $dir"
[ -z "${tb:-}" ] || echo "tsk board pane: $tb"
