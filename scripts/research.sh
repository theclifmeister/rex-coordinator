#!/usr/bin/env bash
# research.sh <topic-slug> [--repo <name>] [--ref <branch|commit>] <question...> — start a
# read-only worker Claude in a new background Rex tab, without taking focus.
# It reads a detached worktree at .claude/worktrees/_research/<topic>, checked
# out at <ref> (default: the tip of the feature branch, the main checkout's
# current branch), never the main checkout's working tree. Titles the tab
# "research: <topic>". Prints the tab's block ID; the answer lands in
# research/YYMMDD-<topic>.md (the date kept in tasks/research-<topic>.date). tasks/research-<topic>.block holds the block ID and
# tasks/research-<topic>.ref holds "<ref> <short sha>" (a commit given as
# --ref is stored as its short sha, so <ref> = <sha>); finish-task.sh removes
# both and the worktree.
# Workspace mode: --repo <name> (required) picks the repo; the worktree is
# <ws>/<repo>/.claude/worktrees/_research/<topic>, the ref defaults to that
# repo's feature branch, and tasks/research-<topic>.repo records the repo.
source "$(dirname "$0")/lib.sh"
require_coordinator
usage="usage: research.sh <topic-slug> [--repo <name>] [--ref <branch|commit>] <question>"
topic=${1:-}; check_slug "$topic"; shift
ref='' repo='' repo_given=0
while [ $# -gt 0 ]; do
  case $1 in
    --ref) [ -n "${2:-}" ] || die "$usage"; ref=$2; shift 2 ;;
    --repo) [ -n "${2:-}" ] || die "$usage"; repo=$2; repo_given=1; shift 2 ;;
    *) break ;;
  esac
done
q="$*"; [ -n "$q" ] || die "$usage"
dir=$(state_dir); coord=$(state_get block); ws=
if ws=$(ws_root); then
  ws_check_repo "$repo"; root="$ws/$repo"
else
  [ $repo_given = 0 ] || die "--repo is for workspace mode only: this coordinator covers one repo"
  root=$(repo_root)
fi
[ -n "$ref" ] || ref=$(feature_branch ${ws:+"$repo"}) || die "no feature branch (main checkout on no branch, none recorded) and no --ref given"
wt="$root/.claude/worktrees/_research/$topic"
blockf="$dir/tasks/research-$topic.block"; reff="$dir/tasks/research-$topic.ref"
datef="$dir/tasks/research-$topic.date"; repof="$dir/tasks/research-$topic.repo"

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
[ -z "$ws" ] || ensure_excluded "$root"
git -C "$root" worktree add -q --detach "$wt" "$sha" || die "could not create worktree $wt"
cleanup() { git -C "$root" worktree remove --force "$wt" >/dev/null 2>&1 || true; rm -f "$reff" "$datef" "$repof"; }
trap 'cleanup' ERR
[ -d "$root/node_modules" ] && [ ! -e "$wt/node_modules" ] && ln -s "$root/node_modules" "$wt/node_modules"
echo "$ref $short" > "$reff"
[ -z "$ws" ] || echo "$repo" > "$repof"
today_stamp > "$datef"; answer=$(state_file research "$topic")
reads=$(research_reads "$reff"); reads=${reads/@/ @ }
[ -z "$ws" ] || reads="the repo $repo ($root, one of the separate git repos in the workspace $ws): $reads"

msg="You are a worker, not the coordinator: ignore any coordinator-flow instructions. You are reading $reads, checked out (detached) in $wt. Question: $q. Read-only: change no file except the answer file. Write your answer to $answer, then print RESEARCH DONE $topic, and send it to the coordinator: rex send -b $coord \"RESEARCH DONE $topic: <one line>. Answer: $answer\", then rex send-key -b $coord Enter."
session=$(state_get session)
out=$(rex run -s "$session" --interactive --focus=false --json \
        -c "$wt" --label "research: $topic" -- env CLAUDE_ROLE=worker claude --name "research: $topic" "$msg") \
  || { cleanup; die "rex run failed: $out"; }
block=$(echo "$out" | jq -r '.block_ids[0] // empty' 2>/dev/null) || block=
if [ -z "$block" ] || [ "$block" = null ]; then cleanup; die "could not read block ID from: $out"; fi
trap - ERR
echo "$block" > "$blockf"
echo "$block"
rex_title_window "$session" "$(echo "$out" | jq -r '.window_id // empty' 2>/dev/null)" "research: $topic"
