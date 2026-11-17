#!/usr/bin/env bash
# watch.sh <slug> — fallback for a worker that dies before messaging. Run in
# the background. A task exits when its report file appears, its tab prints a
# REPORT DONE/BLOCKED line (the marker must start the line, after optional
# spaces and Claude Code's "⏺" bullet, so a brief on screen can't trigger it),
# its tab is gone, or its linked board task is blocked and gets a new reply:
#   BOARD REPLY <slug> T<n>: <reply text>
# A research tab exits when its answer file is written or the tab is gone; its
# capture is not scanned, since the instruction typed into it already contains
# "RESEARCH DONE <topic>".
# WATCH_INTERVAL / BOARD_POLL_SECS override the 15 s / 45 s polls (testing only).
source "$(dirname "$0")/lib.sh"
slug=${1:-}; check_slug "$slug"
dir=$(state_dir)
research=0
f="$dir/tasks/$slug.block"
[ -f "$f" ] || { f="$dir/tasks/research-$slug.block"; research=1; }
block=$(cat "$f" 2>/dev/null) || die "no task $slug"
report="$dir/reports/$slug-report.md"; answer="$dir/research/$slug.md"
marker="^[[:space:]]*(⏺[[:space:]]*)?REPORT (DONE|BLOCKED) ${slug//./\\.}([^a-z0-9._-]|$)"

# Board: the reply count of the block open now is the baseline; a block that
# opens later starts from zero.
tsk_id='' tsk_num='' last_board=0 block_at=- seen=0
if [ $research = 0 ] && [ -f "$dir/tasks/$slug.tsk" ] && have_tsk; then
  read -r tsk_id tsk_num < "$dir/tasks/$slug.tsk" || true
fi
board_state() { # prints "<block-at> <reply-count>", or "- 0" when not blocked
  local t; t=$(tsk_task "$tsk_id") || return 1
  jq -r 'if .status == "blocked" and .block != null
         then "\((.block.at // []) | map(tostring) | join(".")) \((.block.replies // []) | length)"
         else "- 0" end' <<<"$t"
}
if [ -n "$tsk_id" ]; then
  read -r block_at seen <<<"$(board_state || echo "- 0")"
fi

while :; do
  if [ $research = 1 ]; then
    [ -s "$answer" ] && { echo "RESEARCH FILE $slug: $answer"; exit 0; }
  else
    [ -f "$report" ] && { echo "REPORT FILE $slug: $report"; exit 0; }
  fi
  rex block inspect "$block" >/dev/null 2>&1 || { echo "TAB GONE $slug ($block) without a report"; exit 1; }
  if [ $research = 0 ]; then
    line=$(rex capture -b "$block" 2>/dev/null | grep -E "$marker" | tail -n1 || true)
    [ -n "$line" ] && { echo "${line#"${line%%[![:space:]]*}"}"; exit 0; }
  fi
  now=$(date +%s)
  if [ -n "$tsk_id" ] && [ $((now - last_board)) -ge "${BOARD_POLL_SECS:-45}" ]; then
    last_board=$now
    if st=$(board_state); then
      read -r at n <<<"$st"
      [ "$at" = "$block_at" ] || { block_at=$at; seen=0; }
      if [ "$at" != - ] && [ "$n" -gt "$seen" ]; then
        text=$(tsk_task "$tsk_id" | jq -r '.block.replies[-1].text // ""' | one_line 300) || text=
        echo "BOARD REPLY $slug $tsk_num: $text"; exit 0
      fi
    fi
  fi
  sleep "${WATCH_INTERVAL:-15}"
done
