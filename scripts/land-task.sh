#!/usr/bin/env bash
# land-task.sh <slug> [--yes] — land a pr-mode task (tasks/<slug>.land = pr)
# as a pull request into its base on its forge (GitHub or Azure DevOps, from
# origin's URL; see the forge layer in lib.sh), instead of a local merge.
#
# Without --yes: check everything and print the plan (the push, the PR it
# would create or reuse, its title and body), then exit 2. Nothing is pushed.
# Every push needs the user's say-so: the coordinator asks, every time, and
# only then reruns with --yes.
# --yes: git push -u origin <slug>, then reuse the open PR for head <slug> or
#   create one (forge_pr_create; gh pr create / az repos pr create). Title: the board
#   task's title, else the report's Summary. Body: the report's Summary,
#   ## Done, ## Checks and ## Open questions, the board T<n>, and the Claude
#   Code attribution line. Records tasks/<slug>.pr (url, number, base, forge,
#   repo, state). A rerun after new commits pushes again and reuses the PR.
#   Board, the first time: the linked task goes to review --on you, mirroring
#   the report as finish-task.sh does for a merge (done "PR <url> into <base>:
#   <Summary>"), plus a "PR: <url>" notes line (once); the link moves to
#   review/<slug>.tsk. The worktree, branch and worker tab stay: the worker
#   fixes what CI finds, until finish-task.sh closes the task after the merge.
# Refuses (listing every reason) unless the task is a pr task, its worktree
# is clean, its branch has commits its base (and origin/<base>) doesn't, and
# origin is on GitHub or Azure DevOps with its CLI installed and logged in
# (forge_check). Exit: 0 done, 1 refused,
# 2 plan only.
# Workspace mode: all of it in the task's repo (tasks/<slug>.repo).
source "$(dirname "$0")/lib.sh"
require_coordinator
usage="usage: land-task.sh <slug> [--yes]"
slug=${1:-}; check_slug "$slug"; shift
yes=0
while [ $# -gt 0 ]; do
  case $1 in
    --yes) yes=1; shift ;;
    *) die "$usage" ;;
  esac
done
dir=$(state_dir)
[ -f "$dir/tasks/$slug.base" ] || [ -f "$dir/tasks/$slug.block" ] || die "no open task $slug"
root=$(task_root "$slug"); wsrepo=$(task_repo "$slug")
wt="$root/.claude/worktrees/$slug"
base=$(task_base "$slug")
label=$(task_label "$slug")
report=$(state_file report "$slug")
prf=$(task_pr_file "$slug")
problems=()
problem() { problems+=("$*"); }

[ "$(task_land "$slug")" = pr ] \
  || die "$label lands by a local merge (tasks/$slug.land): merge it into $base and run finish-task.sh"
[ -n "$base" ] || problem "no base branch recorded for $slug"
git -C "$root" rev-parse --verify -q "refs/heads/$slug" >/dev/null || problem "no branch $slug in $root"
if [ ! -d "$wt" ]; then
  problem "no worktree at $wt"
else
  busy=$(checkout_busy "$wt")
  [ -z "$busy" ] || problem "the worktree $wt has $busy in progress"
  ! checkout_dirty "$wt" || problem "the worktree $wt has uncommitted changes: the worker commits them first"
fi
forge_check "$root" "${wsrepo:-this repo}"
for p in ${FORGE_PROBLEMS[@]+"${FORGE_PROBLEMS[@]}"}; do problem "$p"; done
repo=$FORGE_REPO forge=$FORGE

ahead=0 ahead_origin=''
if [ -n "$base" ] && git -C "$root" rev-parse --verify -q "refs/heads/$slug" >/dev/null; then
  ahead=$(git -C "$root" rev-list --count "$base..$slug" 2>/dev/null || echo 0)
  [ "$ahead" -gt 0 ] || problem "$slug has no commits that $base doesn't have"
  if [ -n "$repo" ]; then
    if git -C "$root" fetch -q origin "$base" 2>/dev/null \
       && git -C "$root" rev-parse --verify -q "refs/remotes/origin/$base" >/dev/null; then
      ahead_origin=$(git -C "$root" rev-list --count "origin/$base..$slug")
      [ "$ahead_origin" -gt 0 ] || problem "$slug has nothing that origin/$base doesn't have"
    else
      problem "could not fetch $base from origin (git fetch origin $base): it must be on $(forge_name) to take a PR"
    fi
  fi
fi

report_refusal() {
  echo "rex-coordinator: land-task refused for $label:" >&2
  for p in "$@"; do echo "  - $p" >&2; done
  exit 1
}
[ ${#problems[@]} = 0 ] || report_refusal "${problems[@]}"

# --- the PR: an open one for this head, else a recorded one that is closed ------
open=$(forge_pr_find "$slug" "$base") \
  || die "could not list the PRs of $repo on $(forge_name) (head $slug)"
read -r pr_url pr_num <<<"$open" || true
if [ -z "$pr_url" ] && [ -n "$(kv_get "$prf" url)" ]; then
  st=$(forge_pr_state "$(kv_get "$prf" url)" || true); st=${st%% *}
  case $st in
    MERGED) die "$(kv_get "$prf" url) is already merged: run finish-task.sh $slug" ;;
    CLOSED) echo "Note: the recorded PR $(kv_get "$prf" url) was closed without merging; a new one would be opened." >&2 ;;
  esac
fi

# --- title and body ----------------------------------------------------------------
tsk_id='' tsk_num=''
lf=$(tsk_link_file "$slug" 2>/dev/null) && read -r tsk_id tsk_num _ < "$lf" || true
summary=$(report_summary "$report")
title=''
[ -z "$tsk_id" ] || title=$(tsk_task "$tsk_id" | jq -r '.title // empty' 2>/dev/null) || title=
[ -n "$title" ] || { [ "$summary" = "(no report)" ] || title=$summary; }
title=$(printf '%s' "${title:-$slug}" | one_line 120)
section() { # section <heading>: "## <heading>" and its text from the report, if it has any
  local t
  t=$(report_section "$report" "$1" | awk 'NF { for (; blank > 0; blank--) print ""; print; seen = 1; next } seen { blank++ }')
  [ -n "$t" ] || return 0
  printf '## %s\n\n%s\n\n' "$1" "$t"
}
body=$(
  if [ -f "$report" ]; then
    echo "$summary"; echo
    section Done; section Checks; section "Open questions"
  else
    echo "No worker report for this task; see the commits."; echo
  fi
  [ -z "$tsk_num" ] || { echo "Board task: $tsk_num"; echo; }
  echo "$ATTRIBUTION"
)

[ -z "$wsrepo" ] || echo "Repo:     $wsrepo ($root)"
echo "Task:     $label, branch $slug ($ahead commit$([ "$ahead" = 1 ] || echo s) ahead of $base, ${ahead_origin:-?} of origin/$base)"
echo "Base:     $base on $repo$([ "$forge" = github ] || echo " ($(forge_name))")"
if [ -n "$pr_url" ]; then echo "PR:       reuse #$pr_num $pr_url"
else echo "PR:       new, title: $title"; fi
if [ $yes = 0 ]; then
  echo
  echo "Not pushed. Would run: git push -u origin $slug, then $(if [ -n "$pr_url" ]; then echo "reuse #$pr_num"; else forge_pr_create_hint "$base" "$slug"; fi)."
  echo "Ask the user (every push needs their say-so), then rerun with --yes."
  if [ -z "$pr_url" ]; then echo; echo "PR body:"; printf '%s\n' "$body" | sed 's/^/  | /'; fi
  exit 2
fi

git -C "$root" push -u origin "$slug" || die "git push -u origin $slug failed"
new=0
if [ -z "$pr_url" ]; then
  tmp=$(mktemp "${TMPDIR:-/tmp}/rexc-pr.XXXXXX"); trap 'rm -f "$tmp"' EXIT
  printf '%s\n' "$body" > "$tmp"
  pr_url=$(forge_pr_create "$base" "$slug" "$title" "$tmp") || die "no PR was created"
  pr_num=$(forge_pr_id "$pr_url"); new=1
fi
created=$(kv_get "$prf" created)
[ "$(kv_get "$prf" url)" = "$pr_url" ] || created=
mkdir -p "$(dirname "$prf")"
{
  printf 'url=%s\nnumber=%s\nbase=%s\nforge=%s\nrepo=%s\ncreated=%s\nstate=OPEN\n' \
    "$pr_url" "$pr_num" "$base" "$forge" "$repo" "${created:-$(date +%F)}"
  [ -z "$wsrepo" ] || echo "ws_repo=$wsrepo"
} > "$prf.tmp.$$" && mv -f "$prf.tmp.$$" "$prf"
if [ $new = 1 ]; then echo "Created PR #$pr_num: $pr_url"
else echo "Pushed $slug; reusing PR #$pr_num: $pr_url"; fi

# Board mirror, the first time (the link is still in tasks/) and after the
# user sent the review back (link in review/, task no longer in review or
# done). Not on other reruns: tsk would replace the round's checks and lose
# the user's marks. Never fails.
mirror=0
if [ -n "$tsk_id" ]; then
  if [ "$lf" = "$dir/tasks/$slug.tsk" ]; then mirror=1
  elif have_tsk && st=$(tsk_task "$tsk_id" | jq -r .status 2>/dev/null) \
       && [ -n "$st" ] && [ "$st" != review ] && [ "$st" != "done" ]; then mirror=1; fi
fi
if [ $mirror = 1 ]; then
  if ! have_tsk; then
    tsk_warn "not installed: $tsk_num left as it is"
  else
    done_text=$(printf 'PR %s into %s: %s' "$pr_url" "${wsrepo:+$wsrepo/}$base" "$summary" | one_line 200)
    next='' checks=''
    if [ -f "$report" ] && checks=$(report_checks "$report"); then
      checks=$(cap_checks "$REVIEW_MAX_CHECKS" <<<"$checks")
      next=$(report_questions "$report")
    fi
    { [ -z "$checks" ] || printf '%s\n' "$checks"; } | tsk_review "$tsk_id" "$done_text" "$next"
    tsk_note_once "$tsk_id" "PR: $pr_url"
    [ ! -f "$report" ] || tsk_note_once "$tsk_id" "Report: $report"
    if [ "$(tsk_task "$tsk_id" | jq -r .status 2>/dev/null)" = review ]; then
      # A fresh link (no seen= line): board-watch.sh reports this round's events.
      mkdir -p "$dir/review"; head -n1 "$lf" > "$dir/review/$slug.tsk.tmp" \
        && mv -f "$dir/review/$slug.tsk.tmp" "$dir/review/$slug.tsk"
      [ "$lf" = "$dir/review/$slug.tsk" ] || rm -f "$lf"
      echo "Board: $tsk_num is in review; board-watch.sh (in the background) hears when the user closes it, sends it back, or the PR merges."
    else
      tsk_warn "$tsk_num is not in review (set it by hand: tsk status $tsk_id review --on you --done \"...\")"
    fi
  fi
fi
echo "Watch its checks in the background: $(dirname "$0")/pr-watch.sh $pr_url"
echo "$pr_url"
