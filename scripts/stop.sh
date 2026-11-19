#!/usr/bin/env bash
# stop.sh — turn the coordinator flow off for this repo. Leaves tasks alone;
# closes the tsk board pane start.sh opened and restores the tab name.
source "$(dirname "$0")/lib.sh"
dir=$(state_dir)
[ -f "$dir/state" ] || { echo "No coordinator is set for this repo."; exit 0; }
open=""
for f in "$dir"/tasks/*.block; do
  [ -e "$f" ] || continue
  f=${f##*/}
  open+="  - ${f%.block}"$'\n'
done
# Undo start.sh's Rex layout: close the tsk pane it recorded (by ID only) and
# give the tab its own name back while it is still called "coordinator".
session=$(state_get session || true)
rex_close_board "$session" "$(state_get tsk_block || true)"
rex_restore_tab "$session" "$(state_get tab_window || true)" "$(state_get tab_label || true)"
rm -f "$dir/state"
echo "Coordinator flow stopped for $(repo_root)."
if [ -n "$open" ]; then
  echo "Still open (tabs/worktrees left as they are):"
  printf '%s' "$open"
fi
