#!/usr/bin/env bash
# pr-watch.sh <pr-url> — wait for a PR's checks (gh pr checks --watch) and
# end with exactly one line: "PR CHECKS PASS <name> <url>" or
# "PR CHECKS FAIL <name> <url>". <name> is the feature for a feature PR
# (features/*.pr; workspace mode "<repo>/<feature>", from ws_repo=) or the
# task slug for a task PR (tasks/<slug>.pr, from land-task.sh; workspace mode
# "<repo>/<slug>"), else the PR's head branch. Run it with run_in_background
# after finish-feature.sh --yes or land-task.sh --yes. It writes nothing but
# checks=PASS|FAIL in a task's tasks/<slug>.pr (status.sh shows it). A PR
# with no checks reported after about two minutes counts as PASS, with a note
# before the line.
source "$(dirname "$0")/lib.sh"
url=${1:-}
[ -n "$url" ] || die "usage: pr-watch.sh <pr-url>"
command -v gh >/dev/null 2>&1 || die "gh (the GitHub CLI) is not installed"
dir=$(state_dir)
feature=''
for f in "$dir"/features/*.pr; do
  [ -f "$f" ] && [ "$(kv_get "$f" url)" = "$url" ] || continue
  feature=$(kv_get "$f" feature)
  # Workspace mode: "<repo>/<feature>" (still one word).
  r=$(kv_get "$f" ws_repo); [ -z "$r" ] || feature="$r/$feature"
  break
done
taskpr=''
if [ -z "$feature" ]; then
  for f in "$dir"/tasks/*.pr; do
    [ -f "$f" ] && [ "$(kv_get "$f" url)" = "$url" ] || continue
    taskpr=$f; feature=$(basename "$f" .pr)
    r=$(kv_get "$f" ws_repo); [ -z "$r" ] || feature="$r/$feature"
    break
  done
fi
[ -n "$feature" ] || feature=$(gh pr view "$url" --json headRefName -q .headRefName 2>/dev/null || true)
feature=${feature:-?}

# New PRs may have no checks registered yet: wait up to ~2 minutes for some.
interval=${PR_WATCH_INTERVAL:-20}
tries=$(( 120 / interval )); [ "$tries" -ge 1 ] || tries=1
none=0
for ((i = 0; i < tries; i++)); do
  out=$(gh pr checks "$url" 2>&1) && break
  if grep -qi 'no checks reported' <<<"$out"; then none=1; sleep "$interval"; continue; fi
  none=0; break
done
if [ $none = 1 ] && grep -qi 'no checks reported' <<<"${out:-}"; then
  echo "Note: no checks reported for $url."
  [ -z "$taskpr" ] || kv_set "$taskpr" checks PASS 2>/dev/null || true
  echo "PR CHECKS PASS $feature $url"
  exit 0
fi
if gh pr checks "$url" --watch --interval "$interval"; then res=PASS; else res=FAIL; fi
[ -z "$taskpr" ] || [ ! -f "$taskpr" ] || kv_set "$taskpr" checks "$res" 2>/dev/null || true
echo "PR CHECKS $res $feature $url"
