#!/usr/bin/env bash
# board-watch.sh — run in the background while any merged task's board task is
# in review (review/<slug>.tsk links, written by finish-task.sh). Polls the
# board read-only every 45 s and exits with one line per event:
#   BOARD SENT BACK <slug> T<n>: <feedback>   the user sent the review back
#   BOARD DONE <slug> T<n>                    the user closed it (link dropped)
#   BOARD MOVED <slug> T<n>: <status>         any other move out of review
# Each event is reported once (a seen= line in the link file); a sent-back
# link stays until new-task.sh links that task again or the user closes it.
# BOARD_POLL_SECS overrides the interval (for testing only).
source "$(dirname "$0")/lib.sh"
dir=$(state_dir)
interval=${BOARD_POLL_SECS:-45}
have_tsk || { echo "BOARD IDLE: tsk is not installed"; exit 0; }

while :; do
  links=0 events=()
  for f in "$dir"/review/*.tsk; do
    [ -f "$f" ] || continue; links=1
    slug=$(basename "$f" .tsk)
    read -r id num < "$f" || continue
    task=$(tsk_task "$id") || { tsk_warn "could not read $num ($slug); will retry"; continue; }
    status=$(jq -r .status <<<"$task")
    case $status in
      review) continue ;;
      done) events+=("BOARD DONE $slug $num"); rm -f "$f"; continue ;;
    esac
    # Out of review some other way: key the event on the review round that closed.
    key=$(jq -r '(.past_reviews[-1].closed_at // []) | map(tostring) | join(".")' <<<"$task")
    key="$status:$key"
    [ "$(sed -n 's/^seen=//p' "$f")" = "$key" ] && continue
    if [ "$(jq -r '.past_reviews[-1].resolution // ""' <<<"$task")" = sent_back ]; then
      fb=$(jq -r '.past_reviews[-1] | [(.feedback // [])[].text]
                  + [(.checks // [])[] | select(.state == "failed") | "failed check: \(.text)"]
                  | join(" / ")' <<<"$task" | one_line 300)
      events+=("BOARD SENT BACK $slug $num: ${fb:-(no feedback)}")
    else
      events+=("BOARD MOVED $slug $num: $status")
    fi
    { head -n1 "$f"; echo "seen=$key"; } > "$f.tmp" && mv -f "$f.tmp" "$f"
  done
  if [ ${#events[@]} -gt 0 ]; then printf '%s\n' "${events[@]}"; exit 0; fi
  [ $links = 1 ] || { echo "BOARD IDLE: no linked task is in review"; exit 0; }
  sleep "$interval"
done
