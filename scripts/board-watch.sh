#!/usr/bin/env bash
# board-watch.sh — run in the background while any merged task's board task is
# in review (review/<slug>.tsk links, written by finish-task.sh and
# land-task.sh) or a task's PR is open (tasks/<slug>.pr, from land-task.sh).
# Polls read-only every 45 s and exits with one line per event:
#   BOARD SENT BACK <slug> T<n>: <feedback>   the user sent the review back
#   BOARD DONE <slug> T<n>                    the user closed it (link dropped)
#   BOARD MOVED <slug> T<n>: <status>         any other move out of review
#   BOARD PR MERGED <slug> T<n>: <url>        the task's PR was merged (on GitHub
#                                             or Azure DevOps: completed)
#   BOARD PR CLOSED <slug> T<n>: <url>        ... or closed (abandoned) without merging
# (A PR event of a task with no board link leaves out " T<n>".) A task PR
# whose forge's CLI (gh, or az for Azure DevOps) is missing is not polled.
# Each event is reported once: a seen= line in the link file, and the PR's
# state= (and merge_commit=) written to tasks/<slug>.pr. A sent-back link stays
# until new-task.sh links that task again or the user closes it.
# BOARD_POLL_SECS overrides the interval (for testing only).
source "$(dirname "$0")/lib.sh"
dir=$(state_dir)
interval=${BOARD_POLL_SECS:-45}

while :; do
  links=0 prs=0 events=()
  for f in "$dir"/review/*.tsk; do
    [ -f "$f" ] || continue
    have_tsk || break
    links=1
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
  # Task PRs (land-task.sh): merged or closed on their forge, once each.
  for f in "$dir"/tasks/*.pr; do
    [ -f "$f" ] || continue
    case $(kv_get "$f" state) in MERGED|CLOSED) continue ;; esac
    slug=$(basename "$f" .pr); url=$(kv_get "$f" url)
    forge_pr_use "$url" "$f"
    forge_has_cli || continue
    prs=1
    [ -n "$url" ] || continue
    v=$(forge_pr_state "$url") || { echo "rex-coordinator: $(forge_cli): could not read $url ($slug); will retry" >&2; continue; }
    read -r st mc <<<"$v" || true
    case $st in MERGED|CLOSED) ;; *) continue ;; esac
    num=$(tsk_link "$slug" | cut -d' ' -f2)
    kv_set "$f" state "$st"
    [ "$st" != MERGED ] || [ -z "$mc" ] || kv_set "$f" merge_commit "$mc"
    events+=("BOARD PR $st $slug${num:+ $num}: $url")
  done
  if [ ${#events[@]} -gt 0 ]; then printf '%s\n' "${events[@]}"; exit 0; fi
  if [ $links = 0 ] && [ $prs = 0 ]; then
    if have_tsk; then echo "BOARD IDLE: no linked task is in review and no task PR is open"
    else echo "BOARD IDLE: tsk is not installed and no task PR is open"; fi
    exit 0
  fi
  sleep "$interval"
done
