#!/usr/bin/env bash
# status.sh — coordinator state, open tasks, reports waiting, worktrees.
source "$(dirname "$0")/lib.sh"
dir=$(state_dir)
if [ ! -f "$dir/state" ]; then echo "No coordinator set for this repo."; exit 0; fi
root=$(repo_root)
feature=$(state_get feature)
echo "Coordinator block: $(state_get block)"
[ "$(state_get block)" = "${REX_BLOCK:-}" ] && echo "  (this pane)" || echo "  (NOT this pane: ${REX_BLOCK:-none})"
echo "Feature branch:    $feature @ $(git -C "$root" rev-parse --short "$feature")"
echo "Main checkout on:  $(git -C "$root" branch --show-current)"
echo
echo "Open tasks:"
found=0
for f in "$dir"/tasks/*.block; do
  [ -e "$f" ] || continue; found=1
  slug=$(basename "$f" .block); block=$(cat "$f")
  alive=gone; rex block inspect "$block" >/dev/null 2>&1 && alive=open
  report=-; [ -f "$dir/reports/$slug-report.md" ] && report="report ready"
  ahead=$(git -C "$root" rev-list --count "$feature..$slug" 2>/dev/null || echo "?")
  echo "  $slug  tab=$block ($alive)  commits=$ahead  $report"
done
[ $found = 1 ] || echo "  none"
echo
echo "Worktrees:"; git -C "$root" worktree list | sed 's/^/  /'
echo
echo "tsk board:"
if command -v tsk >/dev/null 2>&1; then
  board=$(cd "$root" && tsk list 2>&1)
  if [ -n "$board" ]; then echo "$board" | sed 's/^/  /'
  else echo "  no tasks for this repo (tsk list --all shows every project)"; fi
else
  echo "  tsk not installed"
fi
