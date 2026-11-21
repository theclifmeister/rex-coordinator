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
# Only what is new since the watcher started counts, so a restart after an
# unblock waits instead of firing on the blocked round: a report or answer
# file that exists at start fires only once it changes (other content, or a
# newer mtime than the start), and a marker line already in the tab at start
# fires only when a line with other text appears.
# WATCH_INTERVAL / BOARD_POLL_SECS override the 15 s / 45 s polls (testing only).
source "$(dirname "$0")/lib.sh"
slug=${1:-}; check_slug "$slug"
dir=$(state_dir)
research=0
f="$dir/tasks/$slug.block"
[ -f "$f" ] || { f="$dir/tasks/research-$slug.block"; research=1; }
block=$(cat "$f" 2>/dev/null) || die "no task $slug"
report=$(state_file report "$slug"); answer=$(state_file research "$slug")
marker="^[[:space:]]*(⏺[[:space:]]*)?REPORT (DONE|BLOCKED) ${slug//./\\.}([^a-z0-9._-]|$)"

# Baselines: the file's checksum and a stamp touched now (cksum covers a
# rewrite within the same mtime second; -nt covers one with the same text),
# and the marker lines the tab holds now (trimmed).
tmp=$(mktemp -d "${TMPDIR:-/tmp}/rc-watch.XXXXXX") || die "mktemp failed"
trap 'rm -rf "$tmp"' EXIT
file_sig() { if [ -e "$1" ]; then cksum < "$1"; else echo none; fi; }
markers() { # the tab's marker lines, trimmed, one per line
  rex capture -b "$block" 2>/dev/null | grep -E "$marker" \
    | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' || true
}
if [ $research = 1 ]; then watched=$answer; else watched=$report; fi
start_sig=$(file_sig "$watched")
touch "$tmp/start"
file_new() { # the watched file is there (research: non-empty) and new since start
  if [ $research = 1 ]; then [ -s "$watched" ] || return 1; else [ -f "$watched" ] || return 1; fi
  [ "$start_sig" = none ] || [ "$watched" -nt "$tmp/start" ] || [ "$(file_sig "$watched")" != "$start_sig" ]
}
if [ $research = 0 ]; then markers > "$tmp/markers"; fi

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
  if file_new; then
    if [ $research = 1 ]; then echo "RESEARCH FILE $slug: $answer"; else echo "REPORT FILE $slug: $report"; fi
    exit 0
  fi
  rex block inspect "$block" >/dev/null 2>&1 || { echo "TAB GONE $slug ($block) without a report"; exit 1; }
  if [ $research = 0 ]; then
    line=$(markers | grep -vxF -f "$tmp/markers" | tail -n1 || true)
    [ -n "$line" ] && { echo "$line"; exit 0; }
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
