#!/usr/bin/env bash
# board.sh <slug> <action> — the coordinator's board writes for a task's linked
# tsk task, so no UUID has to be looked up by hand. Actions:
#   show                          the linked task in full (tsk list --json)
#   blocked --why "<question>" [--needs "<what unblocks>"] [--option "<a>"]... [--on <who>]
#                                 put it on the user (repeat to edit the block)
#   unblock ["<answer>"]          with an answer given in chat: record it as a
#                                 reply first (skipped if that reply is already
#                                 there); then set it started --no-dispatch
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
  *)
    die "usage: board.sh <slug> show | blocked --why ... [--needs ...] [--option ...]... | unblock [\"<answer>\"]" ;;
esac
