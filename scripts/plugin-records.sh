#!/usr/bin/env bash
# plugin-records.sh [--fix] — list Claude Code's stale local-scope install
# records of rex-coordinator (installed_plugins.json) for worker worktrees: a
# projectPath under .claude/worktrees/ that is gone, or that is in this repo
# and belongs to no open task or research topic. Records of any other path
# (the main checkout, a live worktree of another repo) and the user-scope
# record are kept.
# --fix removes the stale ones with `claude plugin uninstall --scope local`
# (plugin_drop_local_record in lib.sh); without it nothing changes.
# Run it anywhere but in a worker; inside a repo it also knows that repo's tasks.
source "$(dirname "$0")/lib.sh"
[ "${CLAUDE_ROLE:-}" != worker ] || die "CLAUDE_ROLE=worker: workers don't coordinate"
fix=0
case "${1:-}" in --fix) fix=1 ;; '') ;; *) die "usage: plugin-records.sh [--fix]" ;; esac
command -v jq >/dev/null 2>&1 || die "jq is required"
[ $fix = 0 ] || command -v claude >/dev/null 2>&1 || die "claude is not on PATH"

root='' dir=''
if git rev-parse --git-common-dir >/dev/null 2>&1; then root=$(canon_dir "$(repo_root)"); dir=$(state_dir); fi

owned() { # owned <canonical path under $root/.claude/worktrees/>: an open task or topic has it
  local rel=${1#"$root/.claude/worktrees/"} s
  case $rel in
    _research/*) s=${rel#_research/}; s=${s%%/*}
                 [ -f "$dir/tasks/research-$s.block" ] || [ -f "$dir/tasks/research-$s.ref" ] ;;
    *) s=${rel%%/*}
       [ -f "$dir/tasks/$s.block" ] || [ -f "$dir/tasks/$s.base" ] || [ -f "$dir/tasks/$s.tsk" ] ;;
  esac
}

stale=0 failed=0
while IFS= read -r p; do
  case $p in */.claude/worktrees/*) ;; *) continue ;; esac
  why=''
  if [ ! -e "$p" ]; then
    why=gone
  elif [ -n "$root" ]; then
    c=$(canon_dir "$p")
    case $c in "$root"/.claude/worktrees/*) owned "$c" || why="no open task" ;; esac
  fi
  if [ -z "$why" ]; then echo "keep    $p"; continue; fi
  stale=$((stale + 1))
  if [ $fix = 0 ]; then
    echo "stale   $p ($why)"
  elif [ -n "$(plugin_drop_local_record "$p")" ]; then
    echo "removed $p ($why)"
  else
    echo "FAILED  $p ($why)"; failed=$((failed + 1))
  fi
done < <(plugin_local_records | cut -f2 | sort -u)

if [ $stale = 0 ]; then echo "No stale local plugin records."
elif [ $fix = 0 ]; then echo "$stale stale; run with --fix to remove them."
fi
[ $failed = 0 ]
