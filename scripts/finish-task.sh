#!/usr/bin/env bash
# finish-task.sh <slug> [--abandon] [--check "PASS|FAIL|SKIP <text>"]...
# finish-task.sh <slug> --close-tab
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
# Merged and abandoned ledger lines end with "| base: <base>".
# Workspace mode: the git work happens in the task's repo (tasks/<slug>.repo,
# tasks/research-<topic>.repo), the ledger's slug column is "<repo>/<slug>"
# (one word, so the sha stays field 5) and the board says "into <repo>/<base>".
# A pr-mode task with a PR (tasks/<slug>.pr, from land-task.sh) counts as
# merged when its branch is in <base> or origin/<base>, or gh says the PR is
# MERGED (squash and rebase merges too). Then: git fetch origin <base> and,
# when that repo's main checkout is on <base> and clean, git merge --ff-only
# origin/<base> (else it prints how); the branch goes with -D; a remote branch
# GitHub kept is only named (git push origin --delete is a push: not run).
# The ledger's sha is the PR's merge commit and the line ends "| pr: <url>".
# The board task stays in review (land-task.sh put it there): only a
# "Merged ..." notes line, and any --check goes on through board.sh check.
# --abandon on it: a note, done, and "gh pr close <url>" printed (not run).
# --close-tab: only close the worker's tab (a pr task whose PR checks passed);
# the worktree and branch stay until the PR is merged.
source "$(dirname "$0")/lib.sh"
require_coordinator
slug=${1:-}; check_slug "$slug"; shift
abandon='' extra_checks=() close_tab=0
while [ $# -gt 0 ]; do
  case $1 in
    --abandon) abandon=--abandon; shift ;;
    --close-tab) close_tab=1; shift ;;
    --check) [ $# -ge 2 ] || die "--check needs a value: \"PASS|FAIL|SKIP <text>\""; extra_checks+=("$2"); shift 2 ;;
    --check=*) extra_checks+=("${1#--check=}"); shift ;;
    *) die "usage: finish-task.sh <slug> [--abandon] [--check \"PASS|FAIL|SKIP <text>\"]... | <slug> --close-tab" ;;
  esac
done
dir=$(state_dir); ws=
if [ $close_tab = 1 ]; then
  [ -z "$abandon" ] && [ ${#extra_checks[@]} = 0 ] || die "--close-tab takes no other option"
  tabf="$dir/tasks/$slug.block"
  [ -f "$tabf" ] || die "$slug has no worker tab recorded (tasks/$slug.block)"
  rex block close "$(cat "$tabf")" >/dev/null 2>&1 || true
  rm -f "$tabf"
  echo "Closed the worker tab of $(task_label "$slug"); its worktree and branch stay until finish-task.sh $slug after the merge."
  exit 0
fi
# The task's repo: in workspace mode the one in tasks/<slug>.repo (none: no task).
troot=
if ws=$(ws_root); then
  r=$(task_repo "$slug"); [ -z "$r" ] || troot="$ws/$r"
else
  troot=$(repo_root)
fi
root=$troot
# The branch the task was cut from (tasks/<slug>.base; older tasks: state's feature=).
base=$(task_base "$slug")
brief=$(state_file brief "$slug"); report=$(state_file report "$slug")
answer=$(state_file research "$slug")

# A research tab has no branch: nothing to merge, just close it.
research=0
{ [ -f "$dir/tasks/research-$slug.block" ] || [ -f "$dir/tasks/research-$slug.ref" ]; } \
  && [ ! -f "$dir/tasks/$slug.block" ] \
  && { [ -z "$troot" ] || ! git -C "$troot" rev-parse --verify -q "refs/heads/$slug" >/dev/null; } && research=1
key=$slug; [ $research = 0 ] || key=research-$slug
[ -n "$root" ] && [ $research = 0 ] || root=$(task_root "$key")
wt="$root/.claude/worktrees/$slug"
label=$(task_label "$key" "$slug")
where="the main checkout"; [ -z "$ws" ] || where="$(task_repo "$key")'s main checkout ($root)"
research_ref=-
if [ $research = 1 ]; then
  wt="$root/.claude/worktrees/_research/$slug"
  # "<ref> <sha>" -> "<ref>@<sha>", or just "<sha>" for a commit
  research_ref=$(research_reads "$dir/tasks/research-$slug.ref")
  [ -n "$research_ref" ] || research_ref=-
fi

# A pr-mode task that went out as a PR (land-task.sh --yes).
prf='' pr_url='' pr_mc=''
if [ $research = 0 ] && [ "$(task_land "$slug")" = pr ] && [ -f "$(task_pr_file "$slug")" ]; then
  prf=$(task_pr_file "$slug"); pr_url=$(kv_get "$prf" url)
  pr_mc=$(kv_get "$prf" merge_commit)
fi

if [ "$abandon" != --abandon ] && [ $research = 0 ]; then
  [ -n "$base" ] || die "no base branch recorded for $slug"
  if [ -n "$pr_url" ]; then
    git -C "$root" fetch -q origin "$base" 2>/dev/null \
      || echo "rex-coordinator: warning: git fetch origin $base failed" >&2
    if ! git -C "$root" merge-base --is-ancestor "$slug" "$base" 2>/dev/null \
       && ! git -C "$root" merge-base --is-ancestor "$slug" "origin/$base" 2>/dev/null; then
      command -v gh >/dev/null 2>&1 || die "$slug is not in $base or origin/$base, and gh is missing to ask GitHub about $pr_url"
      v=$(gh pr view "$pr_url" --json state,mergeCommit 2>/dev/null) || die "could not read $pr_url with gh"
      st=$(jq -r '.state // empty' <<<"$v")
      [ "$st" = MERGED ] || die "$pr_url is ${st:-not readable}, not merged (the user merges it on GitHub; or pass --abandon)"
      pr_mc=$(jq -r '.mergeCommit.oid // empty' <<<"$v"); [ -n "$pr_mc" ] || pr_mc=$(kv_get "$prf" merge_commit)
    fi
    [ -n "$pr_mc" ] || pr_mc=$(gh pr view "$pr_url" --json mergeCommit -q '.mergeCommit.oid // empty' 2>/dev/null || true)
  else
    git -C "$root" merge-base --is-ancestor "$slug" "$base" \
      || die "$slug is not merged into $base, its base (merge it with $where on $base, or pass --abandon)"
  fi
fi

# Ledger line, worked out before the branch goes. Never fails the script.
summary_of() { report_summary "$@"; }
ledger_line() {
  local status sha refs tnum
  tnum=${tsk_num:+ $tsk_num}
  if [ $research = 1 ]; then
    status=research; sha=$research_ref
    refs="research: ${answer#"$dir"/}"
    echo "- $(date +%F) $label $status $sha — $(summary_of "$answer") | $refs"
    return
  fi
  if [ "$abandon" = --abandon ]; then
    status=abandoned
    sha=$(git -C "$root" rev-parse --short -q --verify "refs/heads/$slug" 2>/dev/null) || sha=-
  elif [ -n "$pr_url" ] && [ -n "$pr_mc" ]; then
    status=merged
    sha=$(git -C "$root" rev-parse --short -q --verify "$pr_mc^{commit}" 2>/dev/null) || sha=$(cut -c1-7 <<<"$pr_mc")
  else
    status=merged
    sha=$(git -C "$root" rev-list --merges --ancestry-path --reverse "$slug..$base" 2>/dev/null | head -n1)
    [ -n "$sha" ] || sha=$(git -C "$root" rev-parse "$base" 2>/dev/null) || sha=-
    [ "$sha" = - ] || sha=$(git -C "$root" rev-parse --short "$sha" 2>/dev/null) || sha=-
  fi
  refs="brief: ${brief#"$dir"/} | report: ${report#"$dir"/} | base: ${base:--}${pr_url:+ | pr: $pr_url}"
  echo "- $(date +%F) $label $status ${sha:--}$tnum — $(summary_of "$report") | $refs"
}
tsk_id='' tsk_num='' rev_id='' rev_num=''
if [ $research = 0 ] && [ -f "$dir/tasks/$slug.tsk" ]; then
  read -r tsk_id tsk_num < "$dir/tasks/$slug.tsk" || true
elif [ $research = 0 ] && [ -n "$pr_url" ] && [ -f "$dir/review/$slug.tsk" ]; then
  # land-task.sh already put it in review: the ledger still names it.
  read -r rev_id rev_num _ < "$dir/review/$slug.tsk" || true
  tsk_num=$rev_num
fi
entry=$(ledger_line 2>/dev/null) || entry=
# "- <date> <slug> <status> <sha> ..." -> the sha, for the board.
sha=$(cut -d' ' -f5 <<<"$entry"); summary=$(summary_of "$report" 2>/dev/null) || summary=

# Only this slug's own tab: a task and a research topic may share a name.
tabf="$dir/tasks/$slug.block"; [ $research = 1 ] && tabf="$dir/tasks/research-$slug.block"
if [ -f "$tabf" ]; then
  rex block close "$(cat "$tabf")" >/dev/null 2>&1 || true
  rm -f "$tabf"
fi

# The .date goes too: state_file then finds the dated files by their prefix.
# The .repo goes last (below): task_label and the board text still read it.
if [ $research = 1 ]; then rm -f "$dir/tasks/research-$slug.ref" "$dir/tasks/research-$slug.date"
else rm -f "$dir/tasks/$slug.base" "$dir/tasks/$slug.date"; fi
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
# A remote branch the PR left, before the local one (and its upstream) goes.
remote_left=0
if [ -n "$pr_url" ] && git -C "$root" ls-remote --exit-code --heads origin "$slug" >/dev/null 2>&1; then remote_left=1; fi
if git -C "$root" rev-parse --verify -q "refs/heads/$slug" >/dev/null; then
  # A PR merged on GitHub may be a squash or rebase: not an ancestor, so -D
  # (it was checked as merged above).
  if [ "$abandon" = --abandon ] || [ -n "$pr_url" ]; then git -C "$root" branch -D "$slug"
  else git -C "$root" branch -d "$slug"; fi
fi
if [ -n "$pr_url" ]; then
  if [ "$abandon" = --abandon ]; then
    echo "Not done (ask the user): gh pr close $pr_url"
  else
    # Bring the main checkout up to the merged base, when that is safe.
    if [ "$(checkout_branch "$root")" = "$base" ] && [ -z "$(checkout_busy "$root")" ] && ! checkout_dirty "$root"; then
      if git -C "$root" merge -q --ff-only "origin/$base" 2>/dev/null; then
        echo "Fast-forwarded $where ($base) to origin/$base @ $(git -C "$root" rev-parse --short HEAD)."
      else
        echo "Could not fast-forward $where ($base) to origin/$base (diverged?): look at it with git -C $root log --oneline --graph $base origin/$base"
      fi
    else
      echo "Not fast-forwarded: $where is not on a clean $base. To catch up: git -C $root checkout $base && git -C $root merge --ff-only origin/$base"
    fi
  fi
  [ $remote_left = 0 ] || echo "The branch $slug is still on origin; to delete it (a push: ask the user): git -C $root push origin --delete $slug"
fi
[ -z "$entry" ] || { echo "$entry" >> "$dir/history.md"; } 2>/dev/null || true

# Board mirror. Never fails: the git work above is done.
# A PR task land-task.sh already put in review: just a note.
if [ -n "$rev_id" ] && have_tsk; then
  if [ "$abandon" = --abandon ]; then
    tsk_note_once "$rev_id" "Abandoned $(date +%F): branch $slug${ws:+ in $(task_repo "$slug")} (last ${sha:--}) deleted, worktree removed; PR $pr_url not closed by the plugin."
    tsk_try status "$rev_id" "done"
    rm -f "$dir/review/$slug.tsk"
  else
    tsk_note_once "$rev_id" "Merged $(date +%F) as ${sha:--} into ${ws:+$(task_repo "$slug")/}$base (PR $pr_url)."
    # The coordinator's --checks go onto the open round, keeping the user's marks.
    [ ${#extra_checks[@]} = 0 ] || "$(dirname "$0")/board.sh" "$slug" check "${extra_checks[@]}" || true
  fi
fi
if [ -n "$tsk_id" ]; then
  if ! have_tsk; then
    tsk_warn "not installed: $tsk_num left as it is"
  elif [ "$abandon" = --abandon ]; then
    note="Abandoned $(date +%F): branch $slug${ws:+ in $(task_repo "$slug")} (last ${sha:--}) deleted, worktree removed."
    tsk_note_once "$tsk_id" "$note"
    tsk_try status "$tsk_id" "done"
  else
    done_text=$(printf 'Merged %s into %s: %s' "${sha:--}" "${ws:+$(task_repo "$slug")/}$base" "${summary:-(no report)}" | one_line 200)
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
[ $research = 1 ] || rm -f "$dir/tasks/$slug.land" "$dir/tasks/$slug.pr"
rm -f "$dir/tasks/$key.repo"
echo "Closed $label."
