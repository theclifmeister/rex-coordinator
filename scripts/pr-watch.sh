#!/usr/bin/env bash
# pr-watch.sh <pr-url> — wait for a PR's checks and end with exactly one line: "PR CHECKS PASS <name> <url>" or
# "PR CHECKS FAIL <name> <url>". <name> is the feature for a feature PR
# (features/*.pr; workspace mode "<repo>/<feature>", from ws_repo=) or the
# task slug for a task PR (tasks/<slug>.pr, from land-task.sh; workspace mode
# "<repo>/<slug>"), else the PR's head branch. Run it with run_in_background
# after finish-feature.sh --yes or land-task.sh --yes. It writes nothing but
# checks=PASS|FAIL in a task's tasks/<slug>.pr (status.sh shows it). A PR
# with no checks reported after about two minutes counts as PASS, with a note
# before the line.
# The forge (forge_pr_watch in lib.sh) comes from the PR's record (forge=),
# else from the URL. GitHub: gh pr checks --watch. Azure DevOps: the PR's
# Build and Status policies (az repos pr policy list), polled every
# PR_WATCH_INTERVAL seconds (20) for up to PR_WATCH_TIMEOUT (3 hours; then
# FAIL with a note).
source "$(dirname "$0")/lib.sh"
url=${1:-}
[ -n "$url" ] || die "usage: pr-watch.sh <pr-url>"
dir=$(state_dir)
feature='' rec=''
for f in "$dir"/features/*.pr; do
  [ -f "$f" ] && [ "$(kv_get "$f" url)" = "$url" ] || continue
  feature=$(kv_get "$f" feature); rec=$f
  # Workspace mode: "<repo>/<feature>" (still one word).
  r=$(kv_get "$f" ws_repo); [ -z "$r" ] || feature="$r/$feature"
  break
done
taskpr=''
if [ -z "$feature" ]; then
  for f in "$dir"/tasks/*.pr; do
    [ -f "$f" ] && [ "$(kv_get "$f" url)" = "$url" ] || continue
    taskpr=$f rec=$f; feature=$(basename "$f" .pr)
    r=$(kv_get "$f" ws_repo); [ -z "$r" ] || feature="$r/$feature"
    break
  done
fi
forge_pr_use "$url" "$rec"
case $FORGE in
  azdo) command -v az >/dev/null 2>&1 || die "az (the Azure CLI) is not installed" ;;
  *) command -v gh >/dev/null 2>&1 || die "gh (the GitHub CLI) is not installed" ;;
esac
[ -n "$feature" ] || feature=$(forge_pr_head "$url" || true)
feature=${feature:-?}

forge_pr_watch "$url" "${PR_WATCH_INTERVAL:-20}"
res=$FORGE_RESULT
[ -z "$taskpr" ] || [ ! -f "$taskpr" ] || kv_set "$taskpr" checks "$res" 2>/dev/null || true
echo "PR CHECKS $res $feature $url"
