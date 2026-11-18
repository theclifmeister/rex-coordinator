#!/usr/bin/env bash
# bump-version.sh <patch|minor|major> — from a clean main, create branch
# release/vX.Y.Z holding one commit "Release vX.Y.Z" (only plugin.json changed).
# The checkout stays on main, untouched. Does not push, open the PR or tag:
# main only takes pull requests, and CI tags and releases once the PR is merged.
set -euo pipefail
die() { echo "bump-version: $*" >&2; exit 1; }

part=${1:-}
case "$part" in patch|minor|major) ;; *) die "usage: $0 <patch|minor|major>" ;; esac

cd "$(git rev-parse --show-toplevel)"
f=.claude-plugin/plugin.json
branch=$(git symbolic-ref --quiet --short HEAD || true)
[ "$branch" = main ] || die "on '${branch:-detached HEAD}', not main"
if ! git diff --quiet || ! git diff --cached --quiet; then die "working tree has uncommitted changes"; fi

old=$(git show "HEAD:$f" | jq -r '.version // ""')
[[ "$old" =~ ^([0-9]+)\.([0-9]+)\.([0-9]+)$ ]] || die "version '$old' in $f is not x.y.z"
ma=${BASH_REMATCH[1]} mi=${BASH_REMATCH[2]} pa=${BASH_REMATCH[3]}
case "$part" in
  major) new="$((ma + 1)).0.0" ;;
  minor) new="$ma.$((mi + 1)).0" ;;
  patch) new="$ma.$mi.$((pa + 1))" ;;
esac
rel="release/v$new"
git rev-parse -q --verify "refs/heads/$rel" >/dev/null && die "branch $rel already exists"
git rev-parse -q --verify "refs/remotes/origin/$rel" >/dev/null && die "origin/$rel already exists"
git rev-parse -q --verify "refs/tags/v$new" >/dev/null && die "tag v$new already exists"

# Build the commit without touching the checkout: a throwaway index from HEAD,
# with only plugin.json replaced.
mode=$(git ls-files -s -- "$f" | awk '{print $1}')
[ -n "$mode" ] || die "$f is not tracked"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
git show "HEAD:$f" | jq --arg v "$new" '.version = $v' > "$tmp/plugin.json"
blob=$(git hash-object -w "$tmp/plugin.json")
export GIT_INDEX_FILE="$tmp/index"
git read-tree HEAD
git update-index --cacheinfo "$mode,$blob,$f"
tree=$(git write-tree)
unset GIT_INDEX_FILE
commit=$(git commit-tree "$tree" -p HEAD -m "Release v$new")
git branch "$rel" "$commit"

echo "$old -> $new: branch $rel at $(git rev-parse --short "$rel") (checkout still on main)."
echo "Next steps (main only takes pull requests; gh acts as the repo owner without switching accounts):"
echo "  git push origin $rel"
echo "  GH_TOKEN=\$(gh auth token --user theclifmeister) gh pr create -R theclifmeister/rex-coordinator --base main --head $rel --title 'Release v$new' --fill"
echo "  GH_TOKEN=\$(gh auth token --user theclifmeister) gh pr checks -R theclifmeister/rex-coordinator $rel --watch"
echo "  GH_TOKEN=\$(gh auth token --user theclifmeister) gh pr merge -R theclifmeister/rex-coordinator $rel --merge --delete-branch"
echo "  git pull --ff-only origin main"
echo "CI then tags v$new and creates the GitHub Release."
