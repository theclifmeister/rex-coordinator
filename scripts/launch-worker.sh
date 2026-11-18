#!/usr/bin/env bash
# launch-worker.sh <slug> — start a fresh worker Claude in a new Rex tab, in
# the task's worktree, without taking focus. Prints the worker's block ID.
# With a linked board task: sets it started (--no-dispatch) and, once, appends
# the block, branch, worktree and brief to its notes.
source "$(dirname "$0")/lib.sh"
require_coordinator
slug=${1:-}; check_slug "$slug"
dir=$(state_dir); root=$(repo_root)
wt="$root/.claude/worktrees/$slug"
brief="$dir/briefs/$slug.md"
[ -d "$wt" ] || die "no worktree for $slug (run new-task.sh first)"
[ -f "$brief" ] || die "no brief at $brief"
grep -q '{{TODO' "$brief" && die "brief still has {{TODO}} placeholders: $brief"
[ -f "$dir/tasks/$slug.block" ] && die "$slug already has a worker: $(cat "$dir/tasks/$slug.block")"

msg="You are a worker, not the coordinator. Read $brief and follow it. Always report back as it says, also when you are blocked or stop early."
out=$(rex run -s "$(state_get session)" --interactive --focus=false --json \
        -c "$wt" --label "$slug" -- env CLAUDE_ROLE=worker claude --name "$slug" "$msg")
block=$(echo "$out" | jq -r '.block_ids[0] // empty' 2>/dev/null) || block=
[ -n "$block" ] && [ "$block" != null ] || die "could not read block ID from: $out"
echo "$block" > "$dir/tasks/$slug.block"
echo "$block"

# Board mirror, only after the tab is up. Never fails the launch.
read -r tsk_id _ <<<"$(tsk_link "$slug")" || true
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
