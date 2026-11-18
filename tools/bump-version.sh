#!/usr/bin/env bash
# bump-version.sh <patch|minor|major> — bump .claude-plugin/plugin.json and commit
# "Release vX.Y.Z" on main. Does not push or tag: CI tags and releases after the push.
set -euo pipefail
die() { echo "bump-version: $*" >&2; exit 1; }

part=${1:-}
case "$part" in patch|minor|major) ;; *) die "usage: $0 <patch|minor|major>" ;; esac

cd "$(git rev-parse --show-toplevel)"
f=.claude-plugin/plugin.json
branch=$(git symbolic-ref --quiet --short HEAD || true)
[ "$branch" = main ] || die "on '${branch:-detached HEAD}', not main"
if ! git diff --quiet || ! git diff --cached --quiet; then die "working tree has uncommitted changes"; fi

old=$(jq -r '.version // ""' "$f")
[[ "$old" =~ ^([0-9]+)\.([0-9]+)\.([0-9]+)$ ]] || die "version '$old' in $f is not x.y.z"
ma=${BASH_REMATCH[1]} mi=${BASH_REMATCH[2]} pa=${BASH_REMATCH[3]}
case "$part" in
  major) new="$((ma + 1)).0.0" ;;
  minor) new="$ma.$((mi + 1)).0" ;;
  patch) new="$ma.$mi.$((pa + 1))" ;;
esac

tmp=$(mktemp)
jq --arg v "$new" '.version = $v' "$f" > "$tmp"
cat "$tmp" > "$f"   # keep the file's mode
rm -f "$tmp"
git add "$f"
git commit -q -m "Release v$new"
echo "$old -> $new, committed $(git rev-parse --short HEAD)."
echo "Push to release (CI tags v$new and creates the GitHub Release):"
echo "  git push origin main"
