#!/usr/bin/env bash
# new-task.sh <slug> — branch + worktree off the feature branch, and a brief
# skeleton to fill in. Prints the brief path.
source "$(dirname "$0")/lib.sh"
require_coordinator
slug=${1:-}; check_slug "$slug"
dir=$(state_dir); root=$(repo_root); feature=$(state_get feature)
wt="$root/.claude/worktrees/$slug"
brief="$dir/briefs/$slug.md"

git -C "$root" rev-parse --verify -q "refs/heads/$slug" >/dev/null && die "branch '$slug' already exists"
[ -e "$wt" ] && die "$wt already exists"

git -C "$root" worktree add -q -b "$slug" "$wt" "$feature"

# Project run-time needs that must not be committed (extend as needed).
[ -d "$root/node_modules" ] && [ ! -e "$wt/node_modules" ] && ln -s "$root/node_modules" "$wt/node_modules"

sed -e "s|{{SLUG}}|$slug|g" \
    -e "s|{{WORKTREE}}|$wt|g" \
    -e "s|{{FEATURE}}|$feature|g" \
    -e "s|{{COORDINATOR_BLOCK}}|$(state_get block)|g" \
    -e "s|{{REPORT}}|$dir/reports/$slug-report.md|g" \
    "$(dirname "$0")/../skills/coordinator/brief-template.md" > "$brief"

echo "Worktree: $wt (branch $slug off $feature @ $(git -C "$root" rev-parse --short "$feature"))"
echo "Brief:    $brief"
echo "Fill in every {{TODO}} in the brief, then run launch-worker.sh $slug"
