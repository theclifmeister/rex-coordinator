#!/usr/bin/env bash
# new-task.sh <slug> [--repo <name>] [T<n>] [--title "<text>"] — branch + worktree off the
# feature branch (the main checkout's current branch), and a brief skeleton to
# fill in. Prints the brief path. tasks/<slug>.base records that branch: the
# task merges back into it, even if the main checkout switches meanwhile.
# tasks/<slug>.date holds today's YYMMDD, the prefix of the task's brief
# (briefs/YYMMDD-<slug>.md) and report (reports/YYMMDD-<slug>-report.md).
# Board (when tsk is installed): with T<n>, link that task (it must belong to
# this repo and not be done); without, create one (--title is then required)
# and link it. The link goes to tasks/<slug>.tsk, and the
# board task's title, notes and steps are copied into the brief. The board
# task's thread becomes the feature branch (made a valid thread name): set on
# create, and on link only when it has no thread yet (needs tsk >= 0.14.1).
# Workspace mode: --repo <name> (required; a git repo directly under the
# workspace) picks the repo; the worktree is <ws>/<repo>/.claude/worktrees/<slug>
# off that repo's feature branch, tasks/<slug>.repo records it, and the slug
# must be unused across the workspace. The board task goes in the workspace
# folder's project (no --base: tsk refuses it for a non-git project) on thread
# "<repo>.<feature>"; a linked task may be the workspace's or the repo's own.
# Landing (tasks/<slug>.land): --land pr|merge, else state's land= (start.sh
# --land), else by base (land_by_base: a PR when the base is the repo's
# default branch and origin is on GitHub or Azure DevOps, else a local merge). In pr mode the
# brief's <!-- pr --> lines stay: the branch becomes a PR (land-task.sh).
source "$(dirname "$0")/lib.sh"
require_coordinator
slug=${1:-}; check_slug "$slug"; shift
case $slug in research-*) die "slugs starting with 'research-' are reserved for research topics (tasks/research-<topic>.*): pick another name" ;; esac
want='' title='' repo='' repo_given=0 land=''
usage='usage: new-task.sh <slug> [--repo <name>] [T<n>] [--title "<text>"] [--land pr|merge]'
while [ $# -gt 0 ]; do
  case $1 in
    --repo) [ $# -ge 2 ] || die "--repo needs a value"; repo=$2; repo_given=1; shift 2 ;;
    --repo=*) repo=${1#--repo=}; repo_given=1; shift ;;
    --title) [ $# -ge 2 ] || die "--title needs a value"; title=$2; shift 2 ;;
    --title=*) title=${1#--title=}; shift ;;
    --land) [ $# -ge 2 ] || die "--land needs pr or merge"; land=$2; shift 2 ;;
    --land=*) land=${1#--land=}; shift ;;
    [Tt][0-9]*|[0-9]*) [[ $1 =~ ^[Tt]?[0-9]+$ ]] || die "not a task number: $1"; want=${1#[Tt]}; shift ;;
    *) die "$usage (got '$1')" ;;
  esac
done
case $land in ''|pr|merge) ;; *) die "--land takes pr or merge (got '$land')" ;; esac
dir=$(state_dir); ws=
if ws=$(ws_root); then
  ws_check_repo "$repo"
  root="$ws/$repo"
  # State files are flat (tasks/<slug>.*): one slug per workspace.
  for f in "$dir/tasks/$slug".*; do
    [ -e "$f" ] && die "slug '$slug' is already used in this workspace (tasks/${f##*/}$(r=$(task_repo "$slug"); [ -z "$r" ] || echo ", repo $r")): pick another"
  done
else
  [ $repo_given = 0 ] || die "--repo is for workspace mode only: this coordinator covers one repo"
  root=$(repo_root)
fi
[ -n "$want" ] || ! have_tsk || [ -n "$title" ] \
  || die "no T<n> given, so a board task will be created: pass --title \"<text>\" (verb-first)"
feature=$(feature_branch ${ws:+"$repo"}) || die "no feature branch: check a branch out in the main checkout ($root)"
wt="$root/.claude/worktrees/$slug"
project=$(board_project)
land_why="--land"
if [ -z "$land" ]; then
  land=$(state_get land || true); land_why="the coordinator's default (start.sh --land)"
  case $land in pr|merge) ;; *) land=$(land_by_base "$root" "$feature"); land_why="by base" ;; esac
fi

git -C "$root" rev-parse --verify -q "refs/heads/$slug" >/dev/null && die "branch '$slug' already exists"
[ -e "$wt" ] && die "$wt already exists"

# A named board task is checked before anything is created.
task=
if [ -n "$want" ]; then
  if ! have_tsk; then
    tsk_warn "not installed: T$want not linked"
  else
    rc=0; out=$(tsk list "$want" --json 2>&1) || rc=$?
    if [ $rc = 0 ]; then
      task=$(jq -ce '.[0] // empty' <<<"$out" 2>/dev/null) || die "board: no task T$want"
    elif grep -q 'unknown task' <<<"$out"; then
      die "board: no task T$want"
    else
      tsk_warn "could not read T$want (exit $rc): $out — not linked"
    fi
  fi
  if [ -n "$task" ]; then
    proj=$(jq -r '.project // ""' <<<"$task")
    # Workspace mode: the workspace folder's project, or the repo's own.
    ok=0
    if [ -n "$proj" ]; then
      [ "$(canon_dir "$proj")" != "$(canon_dir "$root")" ] || ok=1
      [ -z "$ws" ] || [ "$(canon_dir "$proj")" != "$(canon_dir "$ws")" ] || ok=1
    fi
    [ $ok = 1 ] || die "board: T$want belongs to ${proj:-the desk}, not ${ws:+$ws or }$root"
    [ "$(jq -r .status <<<"$task")" != "done" ] || die "board: T$want is done"
    for a in $(jq -r '.after[]? // empty' <<<"$task"); do
      s=$(tsk_task "$a" | jq -r '.status' 2>/dev/null) || s=
      [ "$s" = "done" ] || tsk_warn "T$want runs after $a, which is ${s:-unknown}, not done"
    done
  fi
fi

# Each repo keeps its worktrees out of git status (start.sh does the single repo).
[ -z "$ws" ] || ensure_excluded "$root"
git -C "$root" worktree add -q -b "$slug" "$wt" "$feature"
# The task merges back into the branch it was cut from, even after a switch.
mkdir -p "$dir/tasks" "$dir/briefs" "$dir/reports"; echo "$feature" > "$dir/tasks/$slug.base"
[ -z "$ws" ] || echo "$repo" > "$dir/tasks/$slug.repo"
# The creation date prefixes this task's brief and report (state_file in lib.sh).
today_stamp > "$dir/tasks/$slug.date"
echo "$land" > "$dir/tasks/$slug.land"
brief=$(state_file brief "$slug"); report=$(state_file report "$slug")

# Project run-time needs that must not be committed (extend as needed).
[ -d "$root/node_modules" ] && [ ! -e "$wt/node_modules" ] && ln -s "$root/node_modules" "$wt/node_modules"

# No task named: create one in this repo's project, based on the feature branch.
# Its thread is the feature branch (as a thread name). Workspace mode: the
# workspace folder's project, no base, thread "<repo>.<feature>".
thread_of=$feature; [ -z "$ws" ] || thread_of="$repo.$feature"
if [ -z "$want" ] && have_tsk; then
  base_arg=(--base "$feature") thread=$(thread_name "$thread_of") thread_arg=()
  [ -z "$ws" ] || base_arg=()
  [ -z "$thread" ] || thread_arg=(--thread "$thread")
  for _ in 1 2 3; do
    rc=0; out=$(tsk add -p "$project" -t "$title" ${base_arg[@]+"${base_arg[@]}"} ${thread_arg[@]+"${thread_arg[@]}"} --json 2>&1) || rc=$?
    # A refused add saved nothing (exit 1 refusal, exit 2 usage), so add again
    # without what was refused. unknown-base: seen once for an existing local
    # branch, not reproduced. A thread refusal: an older or stricter tsk.
    if [ "$rc" = 1 ] && [ ${#base_arg[@]} -gt 0 ] && grep -q 'unknown-base' <<<"$out"; then
      tsk_warn "base '$feature' refused ($(one_line 120 <<<"$out")); adding without a base"
      base_arg=()
    elif [ "$rc" != 0 ] && [ "$rc" != 3 ] && [ ${#thread_arg[@]} -gt 0 ] && head -n1 <<<"$out" | grep -qi 'thread'; then
      tsk_warn "thread '$thread' refused ($(head -n1 <<<"$out" | one_line 120)); adding without a thread"
      thread_arg=()
    else break; fi
  done
  if [ "$rc" = 0 ] && id=$(jq -re '.id' <<<"$out" 2>/dev/null); then
    task=$(tsk_task "$id") || task=$(jq -c . <<<"$out")
  else
    tsk_warn "add failed (exit $rc): $out — no board task for $slug"
  fi
fi

tsk_id='' tsk_num=''
if [ -n "$task" ]; then
  tsk_id=$(jq -r .id <<<"$task"); tsk_num="T$(jq -r .number <<<"$task")"
  echo "$tsk_id $tsk_num" > "$dir/tasks/$slug.tsk"
  # A linked task without a thread goes on the feature branch's (a created one got it on add).
  [ -z "$want" ] || tsk_set_thread "$tsk_id" "$thread_of"
  # A sent-back task linked again: it is an open task now, not in review.
  for f in "$dir"/review/*.tsk; do
    [ -f "$f" ] && [ "$(head -n1 "$f" | cut -d' ' -f1)" = "$tsk_id" ] && rm -f "$f"
  done
fi

# Fixed placeholders by sed (their values hold no | or newline); the board
# task's free text goes in by awk from a file, never through sed.
sed -e "s|{{SLUG}}|$slug|g" \
    -e "s|{{WORKTREE}}|$wt|g" \
    -e "s|{{FEATURE}}|$feature|g" \
    -e "s|{{COORDINATOR_BLOCK}}|$(state_get block)|g" \
    -e "s|{{REPORT}}|$report|g" \
    -e "s|{{TSK_NUM}}|${tsk_num:-none}|g" \
    -e "s|{{TSK_ID}}|${tsk_id:-none}|g" \
    -e "s|{{REPO}}|${repo:-}|g" \
    -e "s|{{WORKSPACE}}|${ws:-}|g" \
    "$(dirname "$0")/../skills/coordinator/brief-template.md" > "$brief.tmp"
board_text=$(mktemp)
if [ -n "$task" ]; then
  jq -r '"Title: \(.title)\n",
         (if (.notes // "") != "" then "Notes (the user'"'"'s words, verbatim):\n\n\(.notes)\n" else "Notes: none\n" end),
         (if (.steps // []) | length > 0
            then "Steps:\n" + ([.steps[] | "- [\(if .done then "x" else " " end)] \(.text) (short_id \(.short_id))"] | join("\n"))
            else "Steps: none" end)' <<<"$task" > "$board_text"
fi
awk -v linked="${task:+1}" -v wsmode="${ws:+1}" -v prmode="$([ "$land" = pr ] && echo 1)" -v f="$board_text" '
  $0 == "<!-- board -->"  { inboard = 1; next }
  $0 == "<!-- /board -->" { inboard = 0; next }
  $0 == "<!-- workspace -->"  { inws = 1; next }
  $0 == "<!-- /workspace -->" { inws = 0; next }
  inboard && !linked      { next }
  inws && !wsmode         { next }
  $0 == "<!-- pr -->"     { inpr = 1; next }
  $0 == "<!-- /pr -->"    { inpr = 0; next }
  inpr && !prmode         { next }
  $0 == "{{BOARD_TASK}}"  { while ((getline l < f) > 0) print l; next }
  { print }' "$brief.tmp" > "$brief"
rm -f "$brief.tmp" "$board_text"

echo "Worktree: $wt (${ws:+repo $repo, }branch $slug off $feature @ $(git -C "$root" rev-parse --short "$feature"))"
[ -z "$tsk_num" ] || echo "Board:    $tsk_num ($tsk_id), linked in $dir/tasks/$slug.tsk"
if [ "$land" = pr ]; then echo "Lands:    as a PR into $feature ($land_why; land-task.sh $slug once the report is in)"
else echo "Lands:    by a local merge into $feature ($land_why)"; fi
echo "Brief:    $brief"
echo "Fill in every {{TODO}} in the brief, then run launch-worker.sh $slug"
