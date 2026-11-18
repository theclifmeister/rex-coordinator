# shellcheck shell=bash
# Shared helpers for rex-coordinator scripts. Source, don't run.
set -euo pipefail

die() { echo "rex-coordinator: $*" >&2; exit 1; }

# Per-repo state lives inside the git common dir, so it is shared by every
# worktree, never committed, and needs no .gitignore entry.
state_dir() {
  local common
  common=$(git rev-parse --path-format=absolute --git-common-dir 2>/dev/null) \
    || die "not inside a git repository"
  echo "$common/rex-coordinator"
}

state_get() { # state_get <key>
  local f
  f="$(state_dir)/state"
  [ -f "$f" ] || return 0
  sed -n "s/^$1=//p" "$f" | head -n1
}

repo_root() { # main checkout, even when called from a worktree
  dirname "$(git rev-parse --path-format=absolute --git-common-dir)"
}

require_coordinator() {
  [ "${CLAUDE_ROLE:-}" != worker ] || die "CLAUDE_ROLE=worker: workers don't coordinate"
  [ -n "${REX_BLOCK:-}" ] || die "REX_BLOCK is not set: not running in a Rex pane"
  [ -f "$(state_dir)/state" ] || die "no coordinator set for this repo (run /coordinator-start)"
  [ "$(state_get block)" = "$REX_BLOCK" ] \
    || die "this pane ($REX_BLOCK) is not the coordinator ($(state_get block))"
}

state_set() { # state_set <key> <value>: replace (or add) one line of the state file
  local f; f="$(state_dir)/state"
  [ -f "$f" ] || return 0
  awk -v k="$1" -v v="$2" 'index($0, k "=") == 1 { if (!d) print k "=" v; d = 1; next }
    { print } END { if (!d) print k "=" v }' "$f" > "$f.tmp.$$" && mv -f "$f.tmp.$$" "$f"
}

# --- the feature branch ---------------------------------------------------
# The feature branch is whatever branch the main checkout has checked out:
# switching is a plain `git checkout`. state's feature= is the last one seen,
# so a switch is noticed (and reported) once. Each task keeps the branch it was
# cut from in tasks/<slug>.base; tasks from before that file existed use
# state's feature=, which is why a switch pins it into their .base first.

checkout_branch() { # the main checkout's branch; nothing if detached, mid-rebase or unborn
  local root b; root=$(repo_root)
  b=$(git -C "$root" symbolic-ref --short -q HEAD 2>/dev/null) || return 0
  git -C "$root" rev-parse --verify -q "refs/heads/$b" >/dev/null || return 0
  echo "$b"
}

open_task_slugs() { # slugs of open (non-research) tasks, one per line
  local d f s; d="$(state_dir)/tasks"
  for f in "$d"/*.block "$d"/*.tsk "$d"/*.base; do
    [ -f "$f" ] || continue
    s=$(basename "$f"); s=${s%.*}
    case $s in research-*) continue ;; esac
    echo "$s"
  done | sort -u
}

task_base() { # task_base <slug>: the branch the task was cut from (and merges into)
  local f; f="$(state_dir)/tasks/$1.base"
  if [ -s "$f" ]; then head -n1 "$f"; else state_get feature; fi
}

tasks_based_on() { # tasks_based_on <branch>: open task slugs whose base is <branch>, space-separated
  local s out=
  for s in $(open_task_slugs); do [ "$(task_base "$s")" = "$1" ] && out+=" $s"; done
  echo "${out# }"
}

feature_change_note() { # feature_change_note <old> <new>
  local on; on=$(tasks_based_on "$1")
  printf 'feature branch changed from %s to %s' "$1" "$2"
  if [ -n "$on" ]; then
    printf '; open tasks still based on %s: %s (merge each with the main checkout on %s)\n' "$1" "$on" "$1"
  else printf '\n'; fi
}

# resolve_feature: sets FEATURE (the current feature branch), FEATURE_NOTE (the
# change note, when the coordinator sees a new branch for the first time) and
# FEATURE_WARN (when the main checkout is on no branch and the last seen one
# is used). Run in the coordinator pane, it records a new branch as last seen,
# after pinning tasks without a .base to the old one. Returns 1 if there is
# no branch at all.
FEATURE='' FEATURE_NOTE='' FEATURE_WARN=''
resolve_feature() {
  local cur last s d
  FEATURE='' FEATURE_NOTE='' FEATURE_WARN=''
  cur=$(checkout_branch); last=$(state_get feature)
  if [ -z "$cur" ]; then
    [ -n "$last" ] || { FEATURE_WARN="the main checkout is on no branch (detached HEAD or rebase in progress) and no feature branch was recorded"; return 1; }
    FEATURE=$last
    FEATURE_WARN="the main checkout is on no branch (detached HEAD or rebase in progress): using the last feature branch, $last"
    return 0
  fi
  FEATURE=$cur
  if [ -n "$last" ] && [ "$cur" != "$last" ]; then
    FEATURE_NOTE=$(feature_change_note "$last" "$cur")
  fi
  if [ "$cur" != "$last" ] && [ "${CLAUDE_ROLE:-}" != worker ] \
     && [ -n "${REX_BLOCK:-}" ] && [ "$(state_get block)" = "$REX_BLOCK" ]; then
    d="$(state_dir)/tasks"
    if [ -n "$last" ]; then
      for s in $(open_task_slugs); do [ -s "$d/$s.base" ] || echo "$last" > "$d/$s.base"; done
    fi
    state_set feature "$cur"
  fi
  return 0
}

feature_branch() { # the current feature branch on stdout; warning and change note on stderr
  resolve_feature || { echo "rex-coordinator: $FEATURE_WARN" >&2; return 1; }
  [ -z "$FEATURE_WARN" ] || echo "rex-coordinator: $FEATURE_WARN" >&2
  [ -z "$FEATURE_NOTE" ] || echo "rex-coordinator: $FEATURE_NOTE" >&2
  echo "$FEATURE"
}

check_slug() {
  [[ "${1:-}" =~ ^[a-z0-9][a-z0-9._-]*$ ]] || die "slug must be lowercase letters, digits, . _ - (got '${1:-}')"
}

# --- tsk board (optional) -------------------------------------------------
# Every board call is best-effort: skipped when tsk is not installed, and a
# failure only warns (to stderr), never fails the git/Rex work. Project-scoped
# calls always pass -p "$(repo_root)"; starts always pass --no-dispatch.
# A coordinator task's board link is tasks/<slug>.tsk while it is open, and
# review/<slug>.tsk after merge until the user closes it. Line 1 of a link file
# is "<uuid> T<n>"; board-watch.sh may add a "seen=<key>" line.

have_tsk() { command -v tsk >/dev/null 2>&1; }

tsk_warn() { echo "rex-coordinator: tsk: $*" >&2; }

TSK_RC=0
# shellcheck disable=SC2034 # TSK_RC is read by the scripts that source this
tsk_try() { # tsk_try <args...>: run tsk, warn on failure, always return 0; tsk's exit is in $TSK_RC
  TSK_RC=127; have_tsk || return 0
  local out rc=0
  out=$(tsk "$@" 2>&1) || rc=$?
  TSK_RC=$rc
  case $rc in
    0) [ -z "$out" ] || printf 'board: %s\n' "$out" >&2 ;;
    3) tsk_warn "indeterminate (exit 3) on 'tsk $1 ${2:-}': $out — verify with: tsk list ${2:-<task>} --json" ;;
    *) tsk_warn "'tsk $1 ${2:-}' failed (exit $rc): $out" ;;
  esac
  return 0
}

tsk_task() { # tsk_task <task>: that task's JSON object, or return 1
  have_tsk || return 1
  local out
  out=$(tsk list "$1" --json 2>/dev/null) || return 1
  out=$(jq -ce '.[0] // empty' <<<"$out" 2>/dev/null) || return 1
  printf '%s\n' "$out"
}

tsk_link_file() { # tsk_link_file <slug>: path of its link file, or return 1
  local d; d=$(state_dir)
  if [ -f "$d/tasks/$1.tsk" ]; then echo "$d/tasks/$1.tsk"
  elif [ -f "$d/review/$1.tsk" ]; then echo "$d/review/$1.tsk"
  else return 1; fi
}

tsk_link() { # tsk_link <slug>: "<uuid> T<n>" of its linked board task, or nothing
  local f; f=$(tsk_link_file "$1") || return 0
  head -n1 "$f"
}

one_line() { # one_line [max]: stdin squashed to one line, cut to max chars
  tr '\r\n\t' '   ' | tr -s ' ' | sed 's/^ //; s/ $//' | cut -c1-"${1:-200}"
}

canon_dir() { (cd "$1" 2>/dev/null && pwd -P) || echo "$1"; }

# research_reads <ref-file>: what a research topic read, from its
# "<ref> <short sha>" file: "<branch>@<short>" for a named ref, just "<short>"
# for a commit (older files may hold the full hash as <ref>). Nothing if unreadable.
research_reads() {
  awk 'NR==1 && NF>=2 {
         if ($1 == $2 || ($1 ~ /^[0-9a-f]+$/ && index($1, $2) == 1)) print $2
         else print $1 "@" $2
       }' "$1" 2>/dev/null || true
}
