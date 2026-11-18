#!/usr/bin/env bash
# board.sh <slug> <action> — the coordinator's board writes for a task's linked
# tsk task, so no UUID has to be looked up by hand. Actions:
#   show                          the linked task in full (tsk list --json)
#   blocked --why "<question>" [--needs "<what unblocks>"] [--option "<a>"]... [--on <who>]
#                                 put it on the user (repeat to edit the block)
#   unblock ["<answer>"]          with an answer given in chat: record it as a
#                                 reply first (skipped if that reply is already
#                                 there); then set it started --no-dispatch
#   check "PASS|FAIL|SKIP <text>"...
#                                 add checks to the open review round with
#                                 that state, keeping its other checks and
#                                 their states (tsk replaces the whole list
#                                 on every review call); a same-text check is
#                                 replaced
# Board failures only warn; nothing here touches git or Rex.
source "$(dirname "$0")/lib.sh"
require_coordinator
slug=${1:-}; check_slug "$slug"; action=${2:-}; shift 2 || true
link=$(tsk_link "$slug")
[ -n "$link" ] || die "no board task is linked to $slug"
read -r id num <<<"$link"
have_tsk || { tsk_warn "not installed: nothing done for $num"; exit 0; }

case $action in
  show)
    tsk list "$id" --json | jq '.[0]' ;;
  blocked)
    [ $# -gt 0 ] || die "usage: board.sh $slug blocked --why \"<question>\" [--needs ...] [--option ...]... [--on <who>]"
    tsk_try status "$id" blocked "$@"
    [ "$TSK_RC" != 0 ] || echo "$num ($slug) is blocked on the board." ;;
  unblock)
    answer=${1:-}
    if [ -n "$answer" ]; then
      if ! task=$(tsk_task "$id"); then
        tsk_warn "could not read $num: answer not recorded (a reply is not safe to repeat blind)"
      elif [ "$(jq -r .status <<<"$task")" != blocked ]; then
        echo "$num is $(jq -r .status <<<"$task"), not blocked: answer not recorded."
      elif [ "$(jq -r '.block.replies[-1].text // ""' <<<"$task")" = "$answer" ]; then
        echo "$num already has that reply."
      else
        tsk_try reply "$id" -- "$answer"
      fi
    fi
    tsk_try status "$id" started --no-dispatch
    [ "$TSK_RC" != 0 ] || echo "$num ($slug) is started again on the board." ;;
  check)
    [ $# -gt 0 ] || die "usage: board.sh $slug check \"PASS|FAIL|SKIP <text>\"..."
    if ! task=$(tsk_task "$id"); then
      tsk_warn "could not read $num: no check added"; exit 0
    fi
    st=$(jq -r .status <<<"$task")
    [ "$st" = review ] || { echo "$num is $st, not in review: no check added."; exit 0; }
    new=$(for c in "$@"; do check_spec "$c"; done)
    [ -n "$new" ] || die "no check text given"
    # Existing checks with their states, minus any the new ones replace.
    { jq -r '.review.checks[]? | "\(.state)\t\(.text)"' <<<"$task" \
        | awk -F'\t' 'NR == FNR { n[$2] = 1; next } !($2 in n)' <(printf '%s\n' "$new") -
      printf '%s\n' "$new"
    } | tsk_review "$id" "" ""
    echo "$num ($slug): $(grep -c . <<<"$new") check(s) added to the review." ;;
  *)
    die "usage: board.sh <slug> show | blocked --why ... [--needs ...] [--option ...]... | unblock [\"<answer>\"] | check \"PASS|FAIL|SKIP <text>\"..." ;;
esac
