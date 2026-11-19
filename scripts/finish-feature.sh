#!/usr/bin/env bash
# finish-feature.sh [--into <target>] [--title <text>] [--yes] [--merge]
# — wrap the feature branch (the main checkout's branch) up into a GitHub PR
# to <target> (default: origin/HEAD's branch, else main).
#
# Without --yes or --merge: check everything and print what it would do, then
# refuse (exit 2). Nothing is pushed or created. The coordinator shows that to
# the user and reruns with --yes only on the user's say-so.
# --yes: push the feature branch (git push -u origin <feature>), then reuse
#   the open PR for it or create one (body: the tasks the ledger shows merged
#   into the feature and not yet in <target>). Records features/<feature>.pr
#   in the state dir, appends a "pr" ledger line and prints the PR URL.
#   --yes also overrides the warnings: merged tasks still in review on the
#   board, and conflicts with <target>.
# --merge: merge the feature's open PR with a merge commit (gh pr merge
#   --merge), never pushing; only on the user's say-so, after the checks pass
#   (pr-watch.sh). Then git fetch, and print (never do) the follow-ups.
#   Warnings refuse it unless --yes is given too.
# Refuses (listing every reason) with open tasks based on the feature branch,
# a main checkout that is not on a branch, dirty or mid-merge/rebase, feature
# == target, nothing ahead of origin/<target>, or gh missing, logged out or a
# remote that is not GitHub. Exit: 0 done, 1 refused, 2 plan only.
# Single repo for now: everything below is keyed off one $root.
source "$(dirname "$0")/lib.sh"
require_coordinator
usage="usage: finish-feature.sh [--into <target>] [--title <text>] [--yes] [--merge]"
target='' title='' yes=0 merge=0
while [ $# -gt 0 ]; do
  case $1 in
    --into) [ $# -ge 2 ] || die "$usage"; target=$2; shift 2 ;;
    --into=*) target=${1#--into=}; shift ;;
    --title) [ $# -ge 2 ] || die "$usage"; title=$2; shift 2 ;;
    --title=*) title=${1#--title=}; shift ;;
    --yes) yes=1; shift ;;
    --merge) merge=1; shift ;;
    *) die "$usage" ;;
  esac
done
dir=$(state_dir); root=$(repo_root)
attribution='🤖 Generated with [Claude Code](https://claude.com/claude-code)'
problems=() warnings=()
problem() { problems+=("$*"); }
warning() { warnings+=("$*"); }

# --- what to wrap up -------------------------------------------------------
resolve_feature || true
feature=$FEATURE
if [ -z "$(checkout_branch)" ]; then
  problem "the main checkout ($root) is not on a branch (detached HEAD or rebase in progress): check out the feature branch"
  feature=
fi
[ -z "$FEATURE_NOTE" ] || echo "rex-coordinator: $FEATURE_NOTE" >&2
busy=$(checkout_busy "$root")
[ -z "$busy" ] || problem "the main checkout has $busy in progress: finish it first"
! checkout_dirty "$root" || problem "the main checkout ($root) has uncommitted changes: commit or stash them first"

if [ -z "$target" ]; then
  target=$(git -C "$root" symbolic-ref --short -q refs/remotes/origin/HEAD 2>/dev/null || true)
  target=${target#origin/}; target=${target:-main}
fi
[ -z "$feature" ] || [ "$feature" != "$target" ] \
  || problem "the main checkout is on $target, the target itself: check out the feature branch (or pass --into <target>)"
if [ -n "$feature" ]; then
  on=$(tasks_based_on "$feature")
  [ -z "$on" ] || problem "open tasks are based on $feature: $on (merge and finish them, or abandon them, first)"
fi

# --- GitHub ------------------------------------------------------------------
gh_repo() { # gh_repo <url>: HOST/OWNER/REPO for a GitHub remote URL, or return 1
  local u=$1 host path
  case $u in
    https://*|http://*|ssh://*|git://*) u=${u#*://}; u=${u#*@}; host=${u%%/*}; path=${u#*/} ;;
    *@*:*) u=${u#*@}; host=${u%%:*}; path=${u#*:} ;;
    *) return 1 ;;
  esac
  host=${host%%:*}; path=${path%.git}; path=${path%/}
  [ "$host" = github.com ] || [ "$host" = "${GH_HOST:-github.com}" ] || return 1 # GH_HOST: GitHub Enterprise
  [[ $path =~ ^[^/]+/[^/]+$ ]] || return 1
  echo "$host/$path"
}
url=$(git -C "$root" config --get remote.origin.url 2>/dev/null || true)
repo=''
if [ -z "$url" ]; then
  problem "this repo has no 'origin' remote"
elif ! repo=$(gh_repo "$url"); then
  repo=''; problem "origin ($url) is not a GitHub repository"
fi
host=${repo%%/*}
if ! command -v gh >/dev/null 2>&1; then
  problem "gh (the GitHub CLI) is not installed: https://cli.github.com"
elif [ -n "$repo" ] && ! gh auth status --hostname "$host" >/dev/null 2>&1; then
  problem "gh is not logged in to $host (gh auth login)"
fi
ghr() { gh "$@" -R "$repo"; }

# --- the remote target ---------------------------------------------------------
fetched=0
if [ -n "$url" ] && [ -n "$feature" ] && [ "$feature" != "$target" ]; then
  if git -C "$root" fetch -q origin "$target" 2>/dev/null \
     && git -C "$root" rev-parse --verify -q "refs/remotes/origin/$target" >/dev/null; then
    fetched=1
  else
    problem "could not fetch $target from origin (git fetch origin $target)"
  fi
fi
ahead=0
if [ $fetched = 1 ]; then
  ahead=$(git -C "$root" rev-list --count "origin/$target..$feature")
  [ "$ahead" -gt 0 ] || problem "$feature has nothing that origin/$target doesn't have"
fi

# --- the tasks the ledger shows on this feature ---------------------------------
# Ledger lines: "- <date> <slug> <status> <sha>[ T<n>] — <summary> | <refs>".
# A merged task is in this PR when its merge sha is in origin/<target>..<feature>.
# An abandoned one is listed as not included when its last commit forked off
# a commit of the feature that <target> doesn't have (a task cut at the fork
# point itself can't be told apart, so it is left out).
in_feature() { # in_feature <sha>
  git -C "$root" cat-file -e "$1^{commit}" 2>/dev/null \
    && git -C "$root" merge-base --is-ancestor "$1" "$feature" 2>/dev/null \
    && ! git -C "$root" merge-base --is-ancestor "$1" "origin/$target" 2>/dev/null
}
included='' excluded='' slugs=''
if [ $fetched = 1 ] && [ -f "$dir/history.md" ]; then
  while IFS=$'\x1f' read -r slug status sha tnum summary; do
    [ -n "$sha" ] && [ "$sha" != - ] || continue
    item="- $slug${tnum:+ ($tnum)}: $summary"
    case $status in
      merged)
        in_feature "$sha" || continue
        included+="$item"$'\n'; slugs+="$slug " ;;
      abandoned)
        fork=$(git -C "$root" merge-base "$sha" "$feature" 2>/dev/null) || continue
        in_feature "$fork" || continue
        excluded+="- $slug${tnum:+ ($tnum)} (abandoned): $summary"$'\n' ;;
    esac
  done < <(awk '/^- / && NF >= 5 {
      slug = $3; st = $4; sha = $5; t = ($6 ~ /^T[0-9]+$/) ? $6 : ""
      s = $0; i = index(s, " — "); s = (i ? substr(s, i + length(" — ")) : "")
      j = index(s, " | "); if (j) s = substr(s, 1, j - 1)
      printf "%s\037%s\037%s\037%s\037%s\n", slug, st, sha, t, s # \037: empty fields survive read
    }' "$dir/history.md")
fi
n_tasks=$(printf '%s' "$included" | grep -c '^- ' || true)

# Merged tasks of this feature the user hasn't accepted on the board yet.
for f in "$dir"/review/*.tsk; do
  [ -f "$f" ] || continue
  s=$(basename "$f" .tsk)
  case " $slugs" in *" $s "*) ;; *) continue ;; esac
  read -r id num _ < "$f" || true
  st=review
  if have_tsk && t=$(tsk_task "$id"); then st=$(jq -r .status <<<"$t"); fi
  [ "$st" = review ] && warning "$s ($num) is still in review on the board: the user hasn't accepted it"
done

# Conflict pre-check, without touching the checkout.
if [ $fetched = 1 ] && [ "$ahead" -gt 0 ]; then
  gv=$(git --version | sed -nE 's/^git version ([0-9]+)\.([0-9]+).*/\1 \2/p')
  read -r gmaj gmin <<<"${gv:-0 0}"
  if [ "$gmaj" -gt 2 ] || { [ "$gmaj" = 2 ] && [ "$gmin" -ge 38 ]; }; then
    if ! mt=$(git -C "$root" merge-tree --write-tree --name-only --no-messages "origin/$target" "$feature" 2>&1); then
      files=$(tail -n +2 <<<"$mt" | grep -v '^$' | sort -u | head -n 10 | tr '\n' ' ')
      warning "$feature conflicts with origin/$target${files:+ in: ${files% }} (the PR can't merge until that is resolved)"
    fi
  else
    echo "Note: git < 2.38 has no merge-tree --write-tree: conflict check skipped." >&2
  fi
fi

# --- the open PR -------------------------------------------------------------
prf=''; [ -z "$feature" ] || prf=$(feature_pr_file "$feature")
pr_url='' pr_num=''
if [ ${#problems[@]} = 0 ]; then
  open=$(ghr pr list --head "$feature" --state open --json url,number 2>/dev/null) \
    || die "gh pr list failed for $repo (head $feature)"
  pr_url=$(jq -r '.[0].url // empty' <<<"$open" 2>/dev/null || true)
  pr_num=$(jq -r '.[0].number // empty' <<<"$open" 2>/dev/null || true)
fi

record_pr() { # record_pr <url> <number>
  local created; created=$(kv_get "$prf" created); created=${created:-$(date +%F)}
  mkdir -p "$(dirname "$prf")"
  printf 'feature=%s\ntarget=%s\nurl=%s\nnumber=%s\nrepo=%s\ncreated=%s\n' \
    "$feature" "$target" "$1" "$2" "$repo" "$created" > "$prf.tmp.$$" && mv -f "$prf.tmp.$$" "$prf"
}
ledger() { echo "- $(date +%F) $feature pr #$1 — $2 | pr: $3" >> "$dir/history.md" 2>/dev/null || true; }

report_refusal() {
  echo "rex-coordinator: finish-feature refused:" >&2
  for p in "$@"; do echo "  - $p" >&2; done
  exit 1
}
[ ${#problems[@]} = 0 ] || report_refusal "${problems[@]}"

# --- merge ---------------------------------------------------------------------
if [ $merge = 1 ]; then
  [ -n "$pr_url" ] || die "no open PR for $feature on $repo: run finish-feature.sh --yes first"
  git -C "$root" fetch -q origin "$feature" 2>/dev/null || true
  [ "$(git -C "$root" rev-parse "$feature")" = "$(git -C "$root" rev-parse -q --verify "refs/remotes/origin/$feature" || true)" ] \
    || die "$feature has commits origin doesn't have (or the other way round): push it first with finish-feature.sh --yes"
  if [ ${#warnings[@]} -gt 0 ] && [ $yes = 0 ]; then
    report_refusal "${warnings[@]}" "(rerun with --merge --yes if the user still wants it merged)"
  fi
  for w in ${warnings[@]+"${warnings[@]}"}; do echo "Warning (merging anyway, --yes): $w"; done
  ghr pr merge "$pr_url" --merge || die "gh pr merge failed for $pr_url"
  git -C "$root" fetch -q origin 2>/dev/null || echo "Note: git fetch origin failed; run it by hand." >&2
  [ -f "$prf" ] || record_pr "$pr_url" "$pr_num"
  sed -i.bak '/^merged=/d' "$prf" && rm -f "$prf.bak"; echo "merged=$(date +%F)" >> "$prf"
  ledger "$pr_num" "merged into $target" "$pr_url"
  echo "Merged $pr_url into $target (merge commit)."
  echo "Follow-ups (not done; ask the user):"
  echo "  git -C $root checkout $target && git -C $root pull --ff-only   # the feature branch becomes $target"
  echo "  git -C $root branch -d $feature && git -C $root push origin --delete $feature"
  exit 0
fi

# --- push and PR -----------------------------------------------------------------
if [ -z "$title" ]; then
  if [ "$n_tasks" = 1 ]; then
    title="$feature: $(printf '%s' "$included" | sed 's/^- [^:]*: //' | one_line 70)"
  elif [ "$n_tasks" -gt 1 ]; then
    list=$(printf '%s' "$slugs" | tr -s ' ' | sed 's/ $//; s/ /, /g')
    title="$feature: $n_tasks tasks ($list)"
    [ ${#title} -le 90 ] || title="$(cut -c1-86 <<<"$title")…)"
  else
    title="$feature"
  fi
fi
body=$(
  echo "Wraps up the feature branch \`$feature\` into \`$target\` ($ahead commit$([ "$ahead" = 1 ] || echo s))."
  echo
  echo "## Tasks"
  echo
  if [ -n "$included" ]; then printf '%s' "$included"
  else echo "No coordinator tasks recorded for this branch; see the commits."; fi
  if [ -n "$excluded" ]; then
    echo; echo "## Not included"; echo; printf '%s' "$excluded"
  fi
  echo
  echo "$attribution"
)

echo "Feature:  $feature ($ahead commit$([ "$ahead" = 1 ] || echo s) ahead of origin/$target)"
echo "Target:   $target on $repo"
if [ -n "$pr_url" ]; then echo "PR:       reuse #$pr_num $pr_url"
else echo "PR:       new, title: $title"; fi
echo "Tasks:    ${n_tasks:-0} merged${slugs:+ (${slugs% })}"
[ -z "$excluded" ] || echo "Abandoned on this branch (listed under Not included): $(printf '%s' "$excluded" | sed -E 's/^- ([^ ]+).*/\1/' | paste -sd' ' -)"
for w in ${warnings[@]+"${warnings[@]}"}; do echo "Warning:  $w"; done
if [ $yes = 0 ]; then
  echo
  echo "Not pushed. Would run: git push -u origin $feature, then $([ -n "$pr_url" ] && echo "reuse #$pr_num" || echo "gh pr create --base $target --head $feature")."
  echo "Ask the user, then rerun with --yes$([ ${#warnings[@]} = 0 ] || echo " (it also accepts the warnings above)")."
  if [ -z "$pr_url" ]; then echo; echo "PR body:"; printf '%s\n' "$body" | sed 's/^/  | /'; fi
  exit 2
fi

git -C "$root" push -u origin "$feature" || die "git push -u origin $feature failed"
if [ -z "$pr_url" ]; then
  tmp=$(mktemp "${TMPDIR:-/tmp}/rexc-pr.XXXXXX"); trap 'rm -f "$tmp"' EXIT
  printf '%s\n' "$body" > "$tmp"
  out=$(ghr pr create --base "$target" --head "$feature" --title "$title" --body-file "$tmp") \
    || die "gh pr create failed: $out"
  pr_url=$(grep -Eo 'https?://[^ ]+/pull/[0-9]+' <<<"$out" | tail -n1)
  [ -n "$pr_url" ] || die "gh pr create printed no PR URL: $out"
  pr_num=${pr_url##*/}
  record_pr "$pr_url" "$pr_num"
  ledger "$pr_num" "$title" "$pr_url"
  echo "Created PR #$pr_num: $pr_url"
else
  record_pr "$pr_url" "$pr_num"
  echo "Pushed $feature; reusing PR #$pr_num: $pr_url"
fi
echo "Watch its checks in the background: $(dirname "$0")/pr-watch.sh $pr_url"
echo "$pr_url"
