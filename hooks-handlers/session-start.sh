#!/usr/bin/env bash
# SessionStart: if this Rex pane is the repo's (or workspace's) coordinator,
# tell Claude so. Silent everywhere else (other panes, workers, non-git dirs,
# no state).
cat >/dev/null
[ "${CLAUDE_ROLE:-}" = worker ] && exit 0
[ -n "${REX_BLOCK:-}" ] || exit 0
root="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"
# shellcheck source=../scripts/state-path.sh
source "$root/scripts/state-path.sh" 2>/dev/null || exit 0
# Workspace mode: $PWD or a folder above it holds a workspace coordinator's
# state whose block is this pane (lib.sh's state_dir resolves it the same way).
sd=$(ws_state_walk "$PWD" "$REX_BLOCK")
if [ -z "$sd" ]; then
  common=$(git rev-parse --path-format=absolute --git-common-dir 2>/dev/null) || exit 0
  # Read-only: state still in the old place is read there (the first script
  # run, status.sh, moves it).
  sd=$(state_path_for "$common")
  [ -f "$sd/state" ] || sd=$(state_legacy_dir "$common")
fi
state="$sd/state"
[ -f "$state" ] || exit 0
block=$(sed -n 's/^block=//p' "$state" | head -n1)
[ "$block" = "$REX_BLOCK" ] || exit 0
ws=; grep -qx 'mode=workspace' "$state" && ws=$(sed -n 's/^root=//p' "$state" | head -n1)
# Coordinator pane only from here on: everything else stayed silent above.
missing=""
for c in rex jq; do command -v "$c" >/dev/null 2>&1 || missing="$missing $c"; done
last=$(sed -n 's/^feature=//p' "$state" | head -n1)
# tsk >= 0.14.1 is required too (one `tsk --version` call, no jq). An
# unparsable version is left to doctor.sh, which only warns about it.
tskfix=
# shellcheck source=../scripts/tsk-version.sh
if [ -f "$root/scripts/tsk-version.sh" ] && source "$root/scripts/tsk-version.sh"; then
  tsk_version_check
  case $? in
    1) missing="$missing tsk>=$TSK_MIN (not installed)" tskfix=$TSK_FIX ;;
    2) missing="$missing tsk>=$TSK_MIN (this is ${TSK_VER:-unknown})" tskfix=$TSK_FIX ;;
  esac
fi

# open_tasks [<repo>]: open (non-research) task slugs, "<slug> <base>" per
# line; only that repo's (tasks/<slug>.repo) when given.
open_tasks() {
  local f s seen=' ' b
  for f in "$sd"/tasks/*.block "$sd"/tasks/*.tsk "$sd"/tasks/*.base; do
    [ -f "$f" ] || continue
    s=$(basename "$f"); s=${s%.*}
    case $s in research-*) continue ;; esac
    case $seen in *" $s "*) continue ;; esac
    seen="$seen$s "
    if [ -n "${1:-}" ] && [ "$(head -n1 "$sd/tasks/$s.repo" 2>/dev/null)" != "$1" ]; then continue; fi
    b=$(head -n1 "$sd/tasks/$s.base" 2>/dev/null) || b=
    echo "$s $b"
  done
}

if [ -n "$ws" ]; then
  # Workspace mode: each repo's feature branch is its main checkout's branch;
  # feature.<repo>= is the last one seen. Name only the repos that are off
  # their default branch or have open tasks (a workspace may hold many).
  n=0 shown='' change=''
  for d in "$ws"/*/; do
    d=${d%/}; r=${d##*/}
    [ -e "$d/.git" ] || continue
    n=$((n + 1))
    cur=$(git -C "$d" symbolic-ref --short -q HEAD 2>/dev/null) \
      && git -C "$d" rev-parse --verify -q "refs/heads/$cur" >/dev/null 2>&1 || cur=
    def=$(git -C "$d" symbolic-ref --short -q refs/remotes/origin/HEAD 2>/dev/null) && def=${def#origin/} || def=
    if [ -z "$def" ]; then
      for b in main master; do git -C "$d" rev-parse --verify -q "refs/heads/$b" >/dev/null 2>&1 && { def=$b; break; }; done
    fi
    last=$(awk -v k="feature.$r=" 'index($0, k) == 1 { print substr($0, length(k) + 1); exit }' "$state")
    tasks=$(open_tasks "$r" | cut -d' ' -f1 | tr '\n' ' '); tasks=${tasks% }
    if [ -n "$tasks" ] || [ -z "$cur" ] || [ "$cur" != "$def" ]; then
      br=$cur
      if [ -z "$br" ]; then
        br="no branch (detached HEAD or rebase in progress)"
        [ -z "$last" ] || br="$br, last seen $last"
      fi
      shown="$shown
- $r: $br${tasks:+; open tasks: $tasks}"
    fi
    if [ -n "$cur" ] && [ -n "$last" ] && [ "$cur" != "$last" ]; then
      on=$(open_tasks "$r" | awk -v l="$last" '$2 == "" || $2 == l { printf "%s%s", (n++ ? " " : ""), $1 }')
      change="$change
- $r: the feature branch changed from '$last' to '$cur' since last seen. Tell the user."
      [ -z "$on" ] || change="$change Open tasks still based on '$last': $on. Each merges into '$last' (with $r's main checkout on '$last'), never into '$cur'."
    fi
  done
  if [ -n "$shown" ]; then
    fb="Repos off their default branch or with open tasks (the rest are on their default branch):$shown"
  else
    fb="All $n repos are on their default branch, with no open tasks."
  fi
  [ -z "$change" ] || change="

Feature branch switches:$change"
  ctx="This Rex pane ($REX_BLOCK) is the COORDINATOR for the workspace $ws: $n git repos directly under it, each with its own feature branch (the branch checked out in the repo's main checkout $ws/<repo>; switching it is a plain git checkout there). Scripts work from the workspace folder or any repo in it.
$fb$change

In workspace mode every task command names its repo: new-task.sh <slug> --repo <name>, research.sh <topic> --repo <name>, finish-feature.sh --repo <name> (one or more); launch-worker.sh and finish-task.sh read the repo from the task. Merge each task in its repo's main checkout (git -C $ws/<repo>).

Before replying to anything, load the rex-coordinator:coordinator skill and follow it: you only coordinate, and every task goes to a fresh worker Claude in its own Rex tab and worktree. Plugin scripts are in $root/scripts. Start by running $root/scripts/status.sh to pick up tasks from earlier sessions."
else
# The feature branch is the main checkout's current branch; state's feature=
# is the last one seen. Read-only here: status.sh records a switch.
main=$(dirname "$common")
cur=$(git -C "$main" symbolic-ref --short -q HEAD 2>/dev/null) \
  && git -C "$main" rev-parse --verify -q "refs/heads/$cur" >/dev/null 2>&1 || cur=
if [ -n "$cur" ]; then
  fb="the feature branch is '$cur' (the branch checked out in the main checkout $main; switching it is a plain git checkout there)"
else
  fb="the main checkout ($main) is on no branch (detached HEAD or rebase in progress), so the scripts use the last feature branch, '$last'"
fi
change=
if [ -n "$cur" ] && [ -n "$last" ] && [ "$cur" != "$last" ]; then
  # Open tasks still based on the old branch (no .base file = based on feature=).
  on=
  for f in "$sd"/tasks/*.block "$sd"/tasks/*.tsk "$sd"/tasks/*.base; do
    [ -f "$f" ] || continue
    s=$(basename "$f"); s=${s%.*}
    case $s in research-*) continue ;; esac
    case " $on " in *" $s "*) continue ;; esac
    b="$sd/tasks/$s.base"
    if [ -s "$b" ]; then [ "$(head -n1 "$b")" = "$last" ] || continue; fi
    on="${on:+$on }$s"
  done
  change="

The feature branch changed from '$last' to '$cur' since last seen. Tell the user."
  [ -z "$on" ] || change="$change Open tasks still based on '$last': $on. Each merges into '$last' (with the main checkout on '$last'), never into '$cur'."
fi

ctx="This Rex pane ($REX_BLOCK) is the COORDINATOR for this repo; $fb.$change

Before replying to anything, load the rex-coordinator:coordinator skill and follow it: you only coordinate, and every task goes to a fresh worker Claude in its own Rex tab and worktree. Plugin scripts are in $root/scripts. Start by running $root/scripts/status.sh to pick up tasks from earlier sessions."
fi
history="$sd/history.md"
if [ -s "$history" ]; then
  recent=$(grep '^- ' "$history" | tail -n 15)
  [ -z "$recent" ] || ctx="$ctx

Recent coordinator history (oldest first; relative paths are under $sd/):
$recent

Older entries, briefs, reports and research answers: $root/scripts/recall.sh <word> [word...]."
fi
[ -z "$missing" ] || ctx="WARNING: rex-coordinator needs$missing on PATH; its scripts will fail until that is fixed (check with $root/scripts/doctor.sh).${tskfix:+ Without tsk >= $TSK_MIN /coordinator-start refuses and board updates are skipped; $tskfix.} Tell the user.

$ctx"
if command -v jq >/dev/null 2>&1; then
  printf '%s' "$ctx" | jq -Rs '{hookSpecificOutput:{hookEventName:"SessionStart",additionalContext:.}}'
else
  printf '%s\n' "$ctx" # without jq: plain stdout also becomes the session's context
fi
