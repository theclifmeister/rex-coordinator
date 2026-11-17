#!/usr/bin/env bash
# stop.sh — turn the coordinator flow off for this repo. Leaves tasks alone.
source "$(dirname "$0")/lib.sh"
dir=$(state_dir)
[ -f "$dir/state" ] || { echo "No coordinator is set for this repo."; exit 0; }
open=$(ls "$dir/tasks" 2>/dev/null | sed -n 's/\.block$//p' || true)
rm -f "$dir/state"
echo "Coordinator flow stopped for $(repo_root)."
if [ -n "$open" ]; then
  echo "Still open (tabs/worktrees left as they are):"
  echo "$open" | sed 's/^/  - /'
fi
