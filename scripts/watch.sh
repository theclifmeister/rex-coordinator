#!/usr/bin/env bash
# watch.sh <slug> — fallback for a worker that dies before messaging. Run in
# the background. A task exits when its report file appears, its tab prints a
# REPORT DONE/BLOCKED line, or the tab is gone. A research tab exits when its
# answer file is written or the tab is gone; its capture is not scanned, since
# the instruction typed into it already contains "RESEARCH DONE <topic>".
source "$(dirname "$0")/lib.sh"
slug=${1:-}; check_slug "$slug"
dir=$(state_dir)
research=0
f="$dir/tasks/$slug.block"
[ -f "$f" ] || { f="$dir/tasks/research-$slug.block"; research=1; }
block=$(cat "$f" 2>/dev/null) || die "no task $slug"
report="$dir/reports/$slug-report.md"; answer="$dir/research/$slug.md"
while :; do
  if [ $research = 1 ]; then
    [ -s "$answer" ] && { echo "RESEARCH FILE $slug: $answer"; exit 0; }
  else
    [ -f "$report" ] && { echo "REPORT FILE $slug: $report"; exit 0; }
  fi
  rex block inspect "$block" >/dev/null 2>&1 || { echo "TAB GONE $slug ($block) without a report"; exit 1; }
  if [ $research = 0 ]; then
    line=$(rex capture -b "$block" 2>/dev/null | grep -E "REPORT (DONE|BLOCKED) $slug" | tail -n1 || true)
    [ -n "$line" ] && { echo "$line"; exit 0; }
  fi
  sleep 15
done
