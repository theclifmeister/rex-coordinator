#!/usr/bin/env bash
# launch-worker.sh <slug> — start a fresh worker Claude in a new Rex tab, in
# the task's worktree, without taking focus. Prints the worker's block ID.
# Titles the tab "<T-number>: <branch>" (just "<branch>" without a board task).
# With a linked board task: sets it started (--no-dispatch) and, once, appends
# the block, branch, worktree and brief to its notes.
source "$(dirname "$0")/lib.sh"
require_coordinator
slug=${1:-}; check_slug "$slug"
dir=$(state_dir); root=$(repo_root)
wt="$root/.claude/worktrees/$slug"
brief=$(state_file brief "$slug")
[ -d "$wt" ] || die "no worktree for $slug (run new-task.sh first)"
[ -f "$brief" ] || die "no brief at $brief"
grep -q '{{TODO' "$brief" && die "brief still has {{TODO}} placeholders: $brief"
[ -f "$dir/tasks/$slug.block" ] && die "$slug already has a worker: $(cat "$dir/tasks/$slug.block")"

msg="You are a worker, not the coordinator. Read $brief and follow it. Always report back as it says, also when you are blocked or stop early."
session=$(state_get session)
out=$(rex run -s "$session" --interactive --focus=false --json \
        -c "$wt" --label "$slug" -- env CLAUDE_ROLE=worker claude --name "$slug" "$msg")
block=$(echo "$out" | jq -r '.block_ids[0] // empty' 2>/dev/null) || block=
[ -n "$block" ] && [ "$block" != null ] || die "could not read block ID from: $out"
echo "$block" > "$dir/tasks/$slug.block"
echo "$block"

# Tab title "<T-number>: <branch>" (just "<branch>" without a board task).
read -r tsk_id tsk_num _ <<<"$(tsk_link "$slug")" || true
window=$(echo "$out" | jq -r '.window_id // empty' 2>/dev/null) || window=
rex_title_window "$session" "$window" "${tsk_num:+$tsk_num: }$slug"

# Board mirror, only after the tab is up. Never fails the launch.
if [ -n "${tsk_id:-}" ] && have_tsk; then
  tsk_try status "$tsk_id" started --no-dispatch
  if task=$(tsk_task "$tsk_id"); then
    notes=$(jq -r '.notes // ""' <<<"$task")
    if ! grep -qF "$block" <<<"$notes"; then
      tsk_try edit "$tsk_id" --append-notes="Rex worker $(date +%F): block $block · branch $slug off $(task_base "$slug") · worktree $wt · brief $brief"
    fi
  else
    tsk_warn "could not read $tsk_id: notes not updated (append is not safe to repeat blind)"
  fi
fi
