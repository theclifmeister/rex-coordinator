#!/usr/bin/env bash
# research.sh <topic-slug> [--ref <branch|commit>] <question...> — start a
# read-only worker Claude in a new background Rex tab, without taking focus.
# It reads a detached worktree at .claude/worktrees/_research/<topic>, checked
# out at <ref> (default: the tip of the feature branch, the main checkout's
# current branch), never the main checkout's
# working tree. Prints the tab's block ID; the answer lands in
# research/<topic>.md. tasks/research-<topic>.block holds the block ID and
# tasks/research-<topic>.ref holds "<ref> <short sha>" (a commit given as
# --ref is stored as its short sha, so <ref> = <sha>); finish-task.sh removes
# both and the worktree.
source "$(dirname "$0")/lib.sh"
require_coordinator
usage="usage: research.sh <topic-slug> [--ref <branch|commit>] <question>"
topic=${1:-}; check_slug "$topic"; shift
ref=
if [ "${1:-}" = --ref ]; then
  [ -n "${2:-}" ] || die "$usage"
  ref=$2; shift 2
fi
q="$*"; [ -n "$q" ] || die "$usage"
[ -n "$ref" ] || ref=$(feature_branch) || die "no feature branch (main checkout on no branch, none recorded) and no --ref given"
dir=$(state_dir); coord=$(state_get block); root=$(repo_root)
answer="$dir/research/$topic.md"
wt="$root/.claude/worktrees/_research/$topic"
blockf="$dir/tasks/research-$topic.block"; reff="$dir/tasks/research-$topic.ref"

sha=$(git -C "$root" rev-parse --verify -q "$ref^{commit}") \
  || die "not a branch or commit: $ref"
short=$(git -C "$root" rev-parse --short "$sha")
# A branch or tag keeps its name; a bare commit (or expression) is its short sha.
[ -n "$(git -C "$root" rev-parse --symbolic-full-name "$ref" 2>/dev/null)" ] || ref=$short
[ -f "$blockf" ] && die "research $topic already has a worker: $(cat "$blockf")"
[ -e "$wt" ] && die "research worktree already exists: $wt (finish-task.sh $topic first)"

# Detached: the feature branch is checked out in the main checkout, and a
# branch can't be checked out in two worktrees.
mkdir -p "$dir/tasks" "$dir/research" "$(dirname "$wt")"
git -C "$root" worktree add -q --detach "$wt" "$sha" || die "could not create worktree $wt"
cleanup() { git -C "$root" worktree remove --force "$wt" >/dev/null 2>&1 || true; rm -f "$reff"; }
trap 'cleanup' ERR
[ -d "$root/node_modules" ] && [ ! -e "$wt/node_modules" ] && ln -s "$root/node_modules" "$wt/node_modules"
echo "$ref $short" > "$reff"
reads=$(research_reads "$reff"); reads=${reads/@/ @ }

msg="You are a worker, not the coordinator: ignore any coordinator-flow instructions. You are reading $reads, checked out (detached) in $wt. Question: $q. Read-only: change no file except the answer file. Write your answer to $answer, then print RESEARCH DONE $topic, and send it to the coordinator: rex send -b $coord \"RESEARCH DONE $topic: <one line>. Answer: $answer\", then rex send-key -b $coord Enter."
out=$(rex run -s "$(state_get session)" --interactive --focus=false --json \
        -c "$wt" --label "research: $topic" -- env CLAUDE_ROLE=worker claude --name "research: $topic" "$msg") \
  || { cleanup; die "rex run failed: $out"; }
block=$(echo "$out" | jq -r '.block_ids[0] // empty' 2>/dev/null) || block=
if [ -z "$block" ] || [ "$block" = null ]; then cleanup; die "could not read block ID from: $out"; fi
trap - ERR
echo "$block" > "$blockf"
echo "$block"
