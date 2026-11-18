#!/usr/bin/env bash
# SessionStart: if this Rex pane is the repo's coordinator, tell Claude so.
# Silent everywhere else (other panes, workers, non-git dirs, no state).
cat >/dev/null
[ "${CLAUDE_ROLE:-}" = worker ] && exit 0
[ -n "${REX_BLOCK:-}" ] || exit 0
common=$(git rev-parse --path-format=absolute --git-common-dir 2>/dev/null) || exit 0
state="$common/rex-coordinator/state"
[ -f "$state" ] || exit 0
block=$(sed -n 's/^block=//p' "$state" | head -n1)
[ "$block" = "$REX_BLOCK" ] || exit 0
# Coordinator pane only from here on: everything else stayed silent above.
missing=""
for c in rex jq; do command -v "$c" >/dev/null 2>&1 || missing="$missing $c"; done
feature=$(sed -n 's/^feature=//p' "$state" | head -n1)
root="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"

ctx="This Rex pane ($REX_BLOCK) is the COORDINATOR for this repo; the feature branch is '$feature'. Before replying to anything, load the rex-coordinator:coordinator skill and follow it: you only coordinate, and every task goes to a fresh worker Claude in its own Rex tab and worktree. Plugin scripts are in $root/scripts. Start by running $root/scripts/status.sh to pick up tasks from earlier sessions."
history="$common/rex-coordinator/history.md"
if [ -s "$history" ]; then
  recent=$(grep '^- ' "$history" | tail -n 15)
  [ -z "$recent" ] || ctx="$ctx

Recent coordinator history (oldest first; relative paths are under $common/rex-coordinator/):
$recent

Older entries, briefs, reports and research answers: $root/scripts/recall.sh <word> [word...]."
fi
[ -z "$missing" ] || ctx="WARNING: rex-coordinator needs$missing on PATH; its scripts will fail until that is installed (check with $root/scripts/doctor.sh). Tell the user.

$ctx"
if command -v jq >/dev/null 2>&1; then
  printf '%s' "$ctx" | jq -Rs '{hookSpecificOutput:{hookEventName:"SessionStart",additionalContext:.}}'
else
  printf '%s\n' "$ctx" # without jq: plain stdout also becomes the session's context
fi
