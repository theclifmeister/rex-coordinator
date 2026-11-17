#!/usr/bin/env bash
# finish-task.sh <slug> [--abandon] — after the task branch is merged into the
# feature branch: close its tab, remove the worktree, delete the branch.
# --abandon skips the merged check and force-deletes (only on the user's say-so).
# A research topic (tasks/research-<slug>.block, no branch): close its tab,
# force-remove its detached worktree .claude/worktrees/_research/<slug> and
# drop tasks/research-<slug>.ref.
# Appends one line per closed task to <state-dir>/history.md (the ledger);
# its paths are relative to the state dir (older lines hold absolute ones).
# Linked board task (tasks/<slug>.tsk): merged -> review on you with the merge
# sha and summary, and the link moves to review/<slug>.tsk for board-watch.sh;
# --abandon -> a note (date, branch, last sha), then done, and the link goes.
source "$(dirname "$0")/lib.sh"
require_coordinator
slug=${1:-}; check_slug "$slug"; abandon=${2:-}
dir=$(state_dir); root=$(repo_root); feature=$(state_get feature)
wt="$root/.claude/worktrees/$slug"

# A research tab has no branch: nothing to merge, just close it.
research=0
{ [ -f "$dir/tasks/research-$slug.block" ] || [ -f "$dir/tasks/research-$slug.ref" ]; } \
  && [ ! -f "$dir/tasks/$slug.block" ] \
  && ! git -C "$root" rev-parse --verify -q "refs/heads/$slug" >/dev/null && research=1
research_ref=-
if [ $research = 1 ]; then
  wt="$root/.claude/worktrees/_research/$slug"
  # "<ref> <sha>" -> "<ref>@<sha>", or just "<sha>" for a commit
  research_ref=$(research_reads "$dir/tasks/research-$slug.ref")
  [ -n "$research_ref" ] || research_ref=-
fi

if [ "$abandon" != --abandon ] && [ $research = 0 ]; then
  git -C "$root" merge-base --is-ancestor "$slug" "$feature" \
    || die "$slug is not merged into $feature (merge first, or pass --abandon)"
fi

# Ledger line, worked out before the branch goes. Never fails the script.
summary_of() { # summary_of <file>: its Summary: line, else first text line
  local f=$1 s=
  if [ -f "$f" ]; then
    s=$(sed -n 's/^[[:space:]]*\**Summary:\**[[:space:]]*//p' "$f" | head -n1)
    [ -n "$s" ] || s=$(grep -v -e '^[[:space:]]*$' -e '^[[:space:]]*#' "$f" | head -n1)
  fi
  s=$(printf '%s' "$s" | tr '\r\n|' '   ' | tr -s ' ' | sed 's/ *$//' | cut -c1-160)
  echo "${s:-(no report)}"
}
ledger_line() {
  local status sha refs tnum
  tnum=${tsk_num:+ $tsk_num}
  if [ $research = 1 ]; then
    status=research; sha=$research_ref
    refs="research: research/$slug.md"
    echo "- $(date +%F) $slug $status $sha — $(summary_of "$dir/research/$slug.md") | $refs"
    return
  fi
  if [ "$abandon" = --abandon ]; then
    status=abandoned
    sha=$(git -C "$root" rev-parse --short -q --verify "refs/heads/$slug" 2>/dev/null) || sha=-
  else
    status=merged
    sha=$(git -C "$root" rev-list --merges --ancestry-path --reverse "$slug..$feature" 2>/dev/null | head -n1)
    [ -n "$sha" ] || sha=$(git -C "$root" rev-parse "$feature" 2>/dev/null) || sha=-
    [ "$sha" = - ] || sha=$(git -C "$root" rev-parse --short "$sha" 2>/dev/null) || sha=-
  fi
  refs="brief: briefs/$slug.md | report: reports/$slug-report.md"
  echo "- $(date +%F) $slug $status ${sha:--}$tnum — $(summary_of "$dir/reports/$slug-report.md") | $refs"
}
tsk_id='' tsk_num=''
if [ $research = 0 ] && [ -f "$dir/tasks/$slug.tsk" ]; then
  read -r tsk_id tsk_num < "$dir/tasks/$slug.tsk" || true
fi
entry=$(ledger_line 2>/dev/null) || entry=
# "- <date> <slug> <status> <sha> ..." -> the sha, for the board.
sha=$(cut -d' ' -f5 <<<"$entry"); summary=$(summary_of "$dir/reports/$slug-report.md" 2>/dev/null) || summary=

# Only this slug's own tab: a task and a research topic may share a name.
tabf="$dir/tasks/$slug.block"; [ $research = 1 ] && tabf="$dir/tasks/research-$slug.block"
if [ -f "$tabf" ]; then
  rex block close "$(cat "$tabf")" >/dev/null 2>&1 || true
  rm -f "$tabf"
fi

[ $research = 0 ] || rm -f "$dir/tasks/research-$slug.ref"
if [ -d "$wt" ]; then
  [ -L "$wt/node_modules" ] && rm "$wt/node_modules"
  # A research worktree is detached and read-only: nothing to keep.
  if [ "$abandon" = --abandon ] || [ $research = 1 ]; then git -C "$root" worktree remove --force "$wt"
  else git -C "$root" worktree remove "$wt"; fi
  [ $research = 0 ] || rmdir "$(dirname "$wt")" 2>/dev/null || true
fi
if git -C "$root" rev-parse --verify -q "refs/heads/$slug" >/dev/null; then
  if [ "$abandon" = --abandon ]; then git -C "$root" branch -D "$slug"
  else git -C "$root" branch -d "$slug"; fi
fi
[ -z "$entry" ] || { echo "$entry" >> "$dir/history.md"; } 2>/dev/null || true

# Board mirror. Never fails: the git work above is done.
if [ -n "$tsk_id" ]; then
  if ! have_tsk; then
    tsk_warn "not installed: $tsk_num left as it is"
  elif [ "$abandon" = --abandon ]; then
    note="Abandoned $(date +%F): branch $slug (last ${sha:--}) deleted, worktree removed."
    if task=$(tsk_task "$tsk_id"); then
      notes=$(jq -r '.notes // ""' <<<"$task")
      grep -qF "$note" <<<"$notes" || tsk_try edit "$tsk_id" --append-notes="$note"
    else
      tsk_warn "could not read $tsk_num: abandon note not added"
    fi
    tsk_try status "$tsk_id" "done"
  else
    tsk_try status "$tsk_id" review --on you \
      --done="$(printf 'Merged %s into %s: %s' "${sha:--}" "$feature" "${summary:-(no report)}" | one_line 200)"
  fi
  # Keep the link for board-watch.sh only while the task is really in review.
  if [ "$abandon" != --abandon ] && [ "$(tsk_task "$tsk_id" | jq -r .status 2>/dev/null)" = review ]; then
    mkdir -p "$dir/review"; mv -f "$dir/tasks/$slug.tsk" "$dir/review/$slug.tsk"
    echo "Board: $tsk_num is in review; run board-watch.sh in the background to hear when the user closes or sends it back."
  else
    [ "$abandon" = --abandon ] || ! have_tsk || tsk_warn "$tsk_num is not in review (set it by hand: tsk status $tsk_id review --on you --done \"...\"); link dropped"
    rm -f "$dir/tasks/$slug.tsk"
  fi
fi
echo "Closed $slug."
