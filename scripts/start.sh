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
  || die "required tools are missing (above): install them, then rerun /coordinator-start"

dir=$(state_dir)
root=$(repo_root)
cur=$(git -C "$root" branch --show-current)
feature=${1:-$cur}
[ -n "$feature" ] || die "main checkout is on a detached HEAD; check out the feature branch, or pass it"
git -C "$root" rev-parse --verify -q "refs/heads/$feature" >/dev/null || die "no local branch '$feature'"
if [ "$feature" != "$cur" ]; then
  gd=$(git -C "$root" rev-parse --path-format=absolute --git-dir)
  for f in MERGE_HEAD CHERRY_PICK_HEAD REVERT_HEAD rebase-merge rebase-apply; do
    [ ! -e "$gd/$f" ] || die "the main checkout ($root) has a merge, rebase or cherry-pick in progress: finish it before switching to '$feature'"
  done
  [ -z "$(git -C "$root" status --porcelain --untracked-files=no)" ] \
    || die "the main checkout ($root) has uncommitted changes: commit or stash them before switching to '$feature' (or run /coordinator-start without a branch to stay on ${cur:-the current HEAD})"
  git -C "$root" checkout -q "$feature" || die "could not check out '$feature' in $root"
  echo "Checked out $feature in the main checkout (was ${cur:-detached})."
fi

old=$(state_get block || true)
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

[ -n "$old" ] && [ "$old" != "$REX_BLOCK" ] && echo "Replaced previous coordinator $old."
echo "Coordinator: $REX_BLOCK"
echo "Feature branch: $feature ($(git -C "$root" rev-parse --short "$feature"))"
echo "State: $dir"
