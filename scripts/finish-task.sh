#!/usr/bin/env bash
# finish-task.sh <slug> [--abandon] — after the task branch is merged into the
# feature branch: close its tab, remove the worktree, delete the branch.
# --abandon skips the merged check and force-deletes (only on the user's say-so).
source "$(dirname "$0")/lib.sh"
require_coordinator
slug=${1:-}; check_slug "$slug"; abandon=${2:-}
dir=$(state_dir); root=$(repo_root); feature=$(state_get feature)
wt="$root/.claude/worktrees/$slug"

# A research pane has no branch: nothing to merge, just close it.
research=0
[ -f "$dir/tasks/research-$slug.block" ] && [ ! -f "$dir/tasks/$slug.block" ] \
  && ! git -C "$root" rev-parse --verify -q "refs/heads/$slug" >/dev/null && research=1

if [ "$abandon" != --abandon ] && [ $research = 0 ]; then
  git -C "$root" merge-base --is-ancestor "$slug" "$feature" \
    || die "$slug is not merged into $feature (merge first, or pass --abandon)"
fi

for f in "$dir/tasks/$slug.block" "$dir/tasks/research-$slug.block"; do
  [ -f "$f" ] || continue
  rex block close "$(cat "$f")" >/dev/null 2>&1 || true
  rm -f "$f"
done

if [ -d "$wt" ]; then
  [ -L "$wt/node_modules" ] && rm "$wt/node_modules"
  if [ "$abandon" = --abandon ]; then git -C "$root" worktree remove --force "$wt"
  else git -C "$root" worktree remove "$wt"; fi
fi
if git -C "$root" rev-parse --verify -q "refs/heads/$slug" >/dev/null; then
  if [ "$abandon" = --abandon ]; then git -C "$root" branch -D "$slug"
  else git -C "$root" branch -d "$slug"; fi
fi
echo "Closed $slug."
