#!/usr/bin/env bash
# new-task.sh <slug> [T<n>] [--title "<text>"] — branch + worktree off the
# feature branch, and a brief skeleton to fill in. Prints the brief path.
# Board (when tsk is installed): with T<n>, link that task (it must belong to
# this repo and not be done); without, create one (title from --title, else
# from the slug) and link it. The link goes to tasks/<slug>.tsk, and the
# board task's title, notes and steps are copied into the brief.
source "$(dirname "$0")/lib.sh"
require_coordinator
slug=${1:-}; check_slug "$slug"; shift
want='' title=''
while [ $# -gt 0 ]; do
  case $1 in
    --title) [ $# -ge 2 ] || die "--title needs a value"; title=$2; shift 2 ;;
    --title=*) title=${1#--title=}; shift ;;
    [Tt][0-9]*|[0-9]*) [[ $1 =~ ^[Tt]?[0-9]+$ ]] || die "not a task number: $1"; want=${1#[Tt]}; shift ;;
    *) die "usage: new-task.sh <slug> [T<n>] [--title \"<text>\"] (got '$1')" ;;
  esac
done
dir=$(state_dir); root=$(repo_root); feature=$(state_get feature)
wt="$root/.claude/worktrees/$slug"
brief="$dir/briefs/$slug.md"

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
    [ -n "$proj" ] && [ "$(canon_dir "$proj")" = "$(canon_dir "$root")" ] \
      || die "board: T$want belongs to ${proj:-the desk}, not $root"
    [ "$(jq -r .status <<<"$task")" != "done" ] || die "board: T$want is done"
    for a in $(jq -r '.after[]? // empty' <<<"$task"); do
      s=$(tsk_task "$a" | jq -r '.status' 2>/dev/null) || s=
      [ "$s" = "done" ] || tsk_warn "T$want runs after $a, which is ${s:-unknown}, not done"
    done
  fi
fi

git -C "$root" worktree add -q -b "$slug" "$wt" "$feature"

# Project run-time needs that must not be committed (extend as needed).
[ -d "$root/node_modules" ] && [ ! -e "$wt/node_modules" ] && ln -s "$root/node_modules" "$wt/node_modules"

# No task named: create one in this repo's project, based on the feature branch.
if [ -z "$want" ] && have_tsk; then
  [ -n "$title" ] || { title=${slug//[-_.]/ }; title="$(tr '[:lower:]' '[:upper:]' <<<"${title:0:1}")${title:1}"; }
  rc=0; out=$(tsk add -p "$root" -t "$title" --base "$feature" --json 2>&1) || rc=$?
  # Seen once, not reproduced: unknown-base for an existing local branch. A
  # refused add saved nothing, so add again without a base.
  if [ $rc = 1 ] && grep -q 'unknown-base' <<<"$out"; then
    tsk_warn "base '$feature' refused ($out); adding without a base"
    rc=0; out=$(tsk add -p "$root" -t "$title" --json 2>&1) || rc=$?
  fi
  if [ $rc = 0 ] && id=$(jq -re '.id' <<<"$out" 2>/dev/null); then
    task=$(tsk_task "$id") || task=$(jq -c . <<<"$out")
  else
    tsk_warn "add failed (exit $rc): $out — no board task for $slug"
  fi
fi

tsk_id='' tsk_num=''
if [ -n "$task" ]; then
  tsk_id=$(jq -r .id <<<"$task"); tsk_num="T$(jq -r .number <<<"$task")"
  echo "$tsk_id $tsk_num" > "$dir/tasks/$slug.tsk"
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
    -e "s|{{REPORT}}|$dir/reports/$slug-report.md|g" \
    -e "s|{{TSK_NUM}}|${tsk_num:-none}|g" \
    -e "s|{{TSK_ID}}|${tsk_id:-none}|g" \
    "$(dirname "$0")/../skills/coordinator/brief-template.md" > "$brief.tmp"
board_text=$(mktemp)
if [ -n "$task" ]; then
  jq -r '"Title: \(.title)\n",
         (if (.notes // "") != "" then "Notes (the user'"'"'s words, verbatim):\n\n\(.notes)\n" else "Notes: none\n" end),
         (if (.steps // []) | length > 0
            then "Steps:\n" + ([.steps[] | "- [\(if .done then "x" else " " end)] \(.text) (short_id \(.short_id))"] | join("\n"))
            else "Steps: none" end)' <<<"$task" > "$board_text"
fi
awk -v linked="${task:+1}" -v f="$board_text" '
  $0 == "<!-- board -->"  { inboard = 1; next }
  $0 == "<!-- /board -->" { inboard = 0; next }
  inboard && !linked      { next }
  $0 == "{{BOARD_TASK}}"  { while ((getline l < f) > 0) print l; next }
  { print }' "$brief.tmp" > "$brief"
rm -f "$brief.tmp" "$board_text"

echo "Worktree: $wt (branch $slug off $feature @ $(git -C "$root" rev-parse --short "$feature"))"
[ -z "$tsk_num" ] || echo "Board:    $tsk_num ($tsk_id), linked in $dir/tasks/$slug.tsk"
echo "Brief:    $brief"
echo "Fill in every {{TODO}} in the brief, then run launch-worker.sh $slug"
