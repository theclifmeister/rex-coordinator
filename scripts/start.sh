#!/usr/bin/env bash
# start.sh [feature-branch] — make this Rex pane the repo's coordinator.
source "$(dirname "$0")/lib.sh"
[ "${CLAUDE_ROLE:-}" != worker ] || die "CLAUDE_ROLE=worker: a worker can't become the coordinator"
[ -n "${REX_BLOCK:-}" ] || die "REX_BLOCK is not set: run this inside a Rex pane"
[ -n "${REX_SESSION:-}" ] || die "REX_SESSION is not set"
bash "$(dirname "$0")/doctor.sh" --quiet \
  || die "required tools are missing (above): install them, then rerun /coordinator-start"

dir=$(state_dir)
root=$(repo_root)
feature=${1:-$(git -C "$root" branch --show-current)}
[ -n "$feature" ] || die "main checkout is on a detached HEAD; pass the feature branch"
git -C "$root" rev-parse --verify -q "refs/heads/$feature" >/dev/null || die "no local branch '$feature'"

old=$(state_get block || true)
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
