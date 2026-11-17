#!/usr/bin/env bash
# research.sh <topic-slug> <question...> — read-only worker in a pane beside
# this one. Prints the pane's block ID; the answer lands in research/<topic>.md.
source "$(dirname "$0")/lib.sh"
require_coordinator
topic=${1:-}; check_slug "$topic"; shift
q="$*"; [ -n "$q" ] || die "usage: research.sh <topic-slug> <question>"
dir=$(state_dir); coord=$(state_get block)
answer="$dir/research/$topic.md"
msg="You are a worker, not the coordinator: ignore any coordinator-flow instructions. Question: $q. Read-only: change no file except the answer file. Write your answer to $answer, then print RESEARCH DONE $topic, and send it to the coordinator: rex send -b $coord \"RESEARCH DONE $topic: <one line>. Answer: $answer\", then rex send-key -b $coord Enter."
out=$(rex run -s "$(state_get session)" -b "$coord" --split=right --interactive --focus=false --json \
        -c "$(repo_root)" --label "research: $topic" -- env CLAUDE_ROLE=worker claude --name "research: $topic" "$msg")
block=$(echo "$out" | jq -r '.block_ids[0]')
echo "$block" > "$dir/tasks/research-$topic.block"
echo "$block"
