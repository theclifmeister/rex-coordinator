#!/usr/bin/env bash
# finish-task.sh <slug> [--abandon] [--check "PASS|FAIL|SKIP <text>"]...
# — after the task branch is merged into its base (tasks/<slug>.base, the
# branch it was cut from; older tasks: state's feature=): close its tab, remove the
# worktree, delete the branch.
# --abandon skips the merged check and force-deletes (only on the user's say-so).
# A research topic (tasks/research-<slug>.block, no branch): close its tab,
# force-remove its detached worktree .claude/worktrees/_research/<slug> and
# drop tasks/research-<slug>.ref.
# Both: drops Claude Code's local-scope plugin record for the worktree's path.
# Appends one line per closed task to <state-dir>/history.md (the ledger);
# its paths are relative to the state dir (older lines hold absolute ones).
# Linked board task (tasks/<slug>.tsk): merged -> review on you with the merge
# sha and summary, plus the report's checks (at most REVIEW_MAX_CHECKS), then
# any --check given here (the coordinator's own, e.g. the full checks on the
# merged branch), all open with the result in the text ("PASS: ..."; the ticks
# are the user's), the report's open questions as
# next and a "Report: <path>" notes line (once); a report without the layout's
# "## Checks" gets the summary only. The link moves to review/<slug>.tsk for
# board-watch.sh. --abandon -> a note (date, branch, last sha), then done, and
# the link goes.
source "$(dirname "$0")/lib.sh"
require_coordinator
slug=${1:-}; check_slug "$slug"; shift
abandon='' extra_checks=()
while [ $# -gt 0 ]; do
  case $1 in
    --abandon) abandon=--abandon; shift ;;
    --check) [ $# -ge 2 ] || die "--check needs a value: \"PASS|FAIL|SKIP <text>\""; extra_checks+=("$2"); shift 2 ;;
    --check=*) extra_checks+=("${1#--check=}"); shift ;;
    *) die "usage: finish-task.sh <slug> [--abandon] [--check \"PASS|FAIL|SKIP <text>\"]..." ;;
  esac
done
dir=$(state_dir); root=$(repo_root)
# The branch the task was cut from (tasks/<slug>.base; older tasks: state's feature=).
base=$(task_base "$slug")
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
  [ -n "$base" ] || die "no base branch recorded for $slug"
  git -C "$root" merge-base --is-ancestor "$slug" "$base" \
    || die "$slug is not merged into $base, its base (merge it with the main checkout on $base, or pass --abandon)"
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
    sha=$(git -C "$root" rev-list --merges --ancestry-path --reverse "$slug..$base" 2>/dev/null | head -n1)
    [ -n "$sha" ] || sha=$(git -C "$root" rev-parse "$base" 2>/dev/null) || sha=-
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

if [ $research = 1 ]; then rm -f "$dir/tasks/research-$slug.ref"; else rm -f "$dir/tasks/$slug.base"; fi
# The local install record Claude Code made for the worker's worktree (see
# plugin_drop_local_record in lib.sh), while the worktree is still there.
# Best-effort and silent on failure; skipped without claude.
[ -z "$(plugin_drop_local_record "$wt")" ] || echo "Dropped Claude Code's local plugin record for $wt."
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
    tsk_note_once "$tsk_id" "$note"
    tsk_try status "$tsk_id" "done"
  else
    report="$dir/reports/$slug-report.md"
    done_text=$(printf 'Merged %s into %s: %s' "${sha:--}" "$base" "${summary:-(no report)}" | one_line 200)
    next='' checks=''
    # The report's checks and open questions, only when it follows the layout.
    if [ -f "$report" ] && checks=$(report_checks "$report"); then
      checks=$(cap_checks "$REVIEW_MAX_CHECKS" <<<"$checks")
      next=$(report_questions "$report")
    fi
    {
      [ -z "$checks" ] || printf '%s\n' "$checks"
      for c in ${extra_checks[@]+"${extra_checks[@]}"}; do check_spec "$c"; done
    } | tsk_review "$tsk_id" "$done_text" "$next"
    [ ! -f "$report" ] || tsk_note_once "$tsk_id" "Report: $report"
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
