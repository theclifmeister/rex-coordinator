#!/usr/bin/env bash
# watch.sh <slug> — fallback for a worker that dies before messaging. Run in
# the background; exits when the report appears, the tab prints a REPORT line,
# or the tab is gone.
source "$(dirname "$0")/lib.sh"
slug=${1:-}; check_slug "$slug"
dir=$(state_dir)
f="$dir/tasks/$slug.block"; [ -f "$f" ] || f="$dir/tasks/research-$slug.block"
block=$(cat "$f" 2>/dev/null) || die "no task $slug"
while :; do
  [ -f "$dir/reports/$slug-report.md" ] && { echo "REPORT FILE $slug: $dir/reports/$slug-report.md"; exit 0; }
  rex block inspect "$block" >/dev/null 2>&1 || { echo "TAB GONE $slug ($block) without a report"; exit 1; }
  line=$(rex capture -b "$block" 2>/dev/null | grep -E "(REPORT (DONE|BLOCKED)|RESEARCH DONE) $slug" | tail -n1 || true)
  [ -n "$line" ] && { echo "$line"; exit 0; }
  sleep 15
done
