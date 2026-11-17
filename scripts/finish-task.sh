#!/usr/bin/env bash
# finish-task.sh <slug> [--abandon] — after the task branch is merged into the
# feature branch: close its tab, remove the worktree, delete the branch.
# --abandon skips the merged check and force-deletes (only on the user's say-so).
# Appends one line per closed task to <state-dir>/history.md (the ledger).
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

# Ledger line, worked out before the branch goes. Never fails the script.
summary_of() { # summary_of <file>: its Summary: line, else first text line
  local f=$1 s=
  if [ -f "$f" ]; then
    s=$(sed -n 's/^[[:space:]]*\**Summary:\**[[:space:]]*//p' "$f" | head -n1)
    [ -n "$s" ] || s=$(grep -v -e '^[[:space:]]*$' -e '^[[:space:]]*#' "$f" | head -n1)
  fi
  s=$(printf '%s' "$s" | tr '\r\n|' '   ' | tr -s ' ' | sed 's/ *$//' | cut -c1-160)
  echo "${s:-(no report)}"
}
ledger_line() {
  local status sha refs
  if [ $research = 1 ]; then
    status=research; sha=-
    refs="research: $dir/research/$slug.md"
    echo "- $(date +%F) $slug $status $sha — $(summary_of "$dir/research/$slug.md") | $refs"
    return
  fi
  if [ "$abandon" = --abandon ]; then
    status=abandoned
    sha=$(git -C "$root" rev-parse --short -q --verify "refs/heads/$slug" 2>/dev/null) || sha=-
  else
    status=merged
    sha=$(git -C "$root" rev-list --merges --ancestry-path --reverse "$slug..$feature" 2>/dev/null | head -n1)
    [ -n "$sha" ] || sha=$(git -C "$root" rev-parse "$feature" 2>/dev/null) || sha=-
    [ "$sha" = - ] || sha=$(git -C "$root" rev-parse --short "$sha" 2>/dev/null) || sha=-
  fi
  refs="brief: $dir/briefs/$slug.md | report: $dir/reports/$slug-report.md"
  echo "- $(date +%F) $slug $status ${sha:--} — $(summary_of "$dir/reports/$slug-report.md") | $refs"
}
entry=$(ledger_line 2>/dev/null) || entry=

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
[ -z "$entry" ] || { echo "$entry" >> "$dir/history.md"; } 2>/dev/null || true
echo "Closed $slug."
