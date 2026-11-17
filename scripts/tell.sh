#!/usr/bin/env bash
# tell.sh <slug> <file | -> — send a worker (task or research tab) a message of
# any length. Long `rex send` input arrives truncated in Claude's prompt, so the
# message goes to messages/<slug>-<n>.md and only one short line is typed in,
# asking the worker to read it and ACK back to the coordinator.
source "$(dirname "$0")/lib.sh"
require_coordinator
slug=${1:-}; check_slug "$slug"; src=${2:-}
[ -n "$src" ] || die "usage: tell.sh <slug> <file | ->  (- reads stdin)"
dir=$(state_dir); coord=$(state_get block)
bf="$dir/tasks/$slug.block"; [ -f "$bf" ] || bf="$dir/tasks/research-$slug.block"
[ -f "$bf" ] || die "no open worker for $slug"
block=$(cat "$bf")
rex block inspect "$block" >/dev/null 2>&1 || die "worker tab for $slug is gone ($block)"

mkdir -p "$dir/messages"
n=1; while [ -e "$dir/messages/$slug-$n.md" ]; do n=$((n+1)); done
msg="$dir/messages/$slug-$n.md"
if [ "$src" = - ]; then cat > "$msg"; else cp "$src" "$msg"; fi
[ -s "$msg" ] || { rm -f "$msg"; die "message is empty"; }

line="Coordinator message: read $msg and act on it. Acknowledge first: rex send -b $coord \"ACK $slug-$n\", then rex send-key -b $coord Enter."
rex send -b "$block" "$line"
rex send-key -b "$block" Enter
echo "Sent $msg to $block; expect 'ACK $slug-$n'."
