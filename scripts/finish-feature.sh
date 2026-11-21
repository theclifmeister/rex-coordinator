#!/usr/bin/env bash
# finish-feature.sh [--repo <name>]... [--into <target>] [--title <text>] [--yes] [--merge]
# — wrap the feature branch (the main checkout's branch) up into a PR to
# <target> (default: origin/HEAD's branch, else main) on its forge: GitHub
# or Azure DevOps, from origin's URL (the forge layer in lib.sh).
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
#   --merge; az repos pr update --status completed --squash false), never pushing; only on the user's say-so, after the checks pass
#   (pr-watch.sh). Then git fetch, and print (never do) the follow-ups.
#   Warnings refuse it unless --yes is given too.
# Refuses (listing every reason) with open tasks based on the feature branch,
# a main checkout that is not on a branch, dirty or mid-merge/rebase, feature
# == target, nothing ahead of origin/<target>, or a remote that is not on
# GitHub or Azure DevOps, or its CLI (gh; az + azure-devops) missing or
# logged out. Exit: 0 done, 1 refused, 2 plan only.
# Workspace mode: --repo <name> (required) runs all of it in that repo
# (<ws>/<repo>, its feature branch, its tasks; ledger lines "<repo>/<slug>";
# the record is features/<repo>--<feature>.pr with ws_repo=<repo>). Several
# --repo flags run it once per repo, after checking all of them first (one
# refusal refuses all); with --yes each repo gets its own PR, every PR body
# then gets a "Part of: <the other PR urls>" line (forge_pr_edit_body), and a summary
# lists them all.
# Everything below is keyed off one $root.
source "$(dirname "$0")/lib.sh"
require_coordinator
usage="usage: finish-feature.sh [--repo <name>]... [--into <target>] [--title <text>] [--yes] [--merge]"
target='' title='' yes=0 merge=0 repos=() fwd=()
while [ $# -gt 0 ]; do
  case $1 in
    --repo) [ $# -ge 2 ] || die "$usage"; repos+=("$2"); shift 2 ;;
    --repo=*) repos+=("${1#--repo=}"); shift ;;
    --into) [ $# -ge 2 ] || die "$usage"; target=$2; fwd+=(--into "$2"); shift 2 ;;
    --into=*) target=${1#--into=}; fwd+=(--into "$target"); shift ;;
    --title) [ $# -ge 2 ] || die "$usage"; title=$2; fwd+=(--title "$2"); shift 2 ;;
    --title=*) title=${1#--title=}; fwd+=(--title "$title"); shift ;;
    --yes) yes=1; shift ;;
    --merge) merge=1; shift ;;
    *) die "$usage" ;;
  esac
done
dir=$(state_dir); ws='' wsrepo=''
if ws=$(ws_root); then
  [ ${#repos[@]} -gt 0 ] || ws_check_repo ''
  for r in "${repos[@]}"; do ws_check_repo "$r"; done
  if [ ${#repos[@]} -gt 1 ]; then
    # One run per repo: first all of them as a plan (nothing pushed), so one
    # refusal stops the lot; then, with --yes or --merge, the real runs.
    seen=' '
    for r in "${repos[@]}"; do
      case $seen in *" $r "*) die "--repo $r is given twice" ;; esac; seen+="$r "
    done
    # With --yes/--merge the plans are only shown for a repo that refuses.
    refused=''
    for r in "${repos[@]}"; do
      rc=0; out=$("$0" --repo "$r" ${fwd[@]+"${fwd[@]}"} 2>&1) || rc=$?
      # --merge refuses on warnings unless --yes: so does the check of every repo.
      if [ "$rc" = 2 ] && [ $merge = 1 ] && [ $yes = 0 ] && grep -q '^Warning:' <<<"$out"; then
        rc=1; out+=$'\n'"(--merge refuses on these warnings: rerun with --merge --yes if the user accepts them)"
      fi
      if [ "$rc" = 1 ] || { [ $yes = 0 ] && [ $merge = 0 ]; }; then
        echo "== $r =="; printf '%s\n\n' "$out"
      fi
      [ "$rc" != 1 ] || refused+=" $r"
    done
    [ -z "$refused" ] || die "finish-feature refused for:$refused (see above); nothing was pushed or merged in any repo"
    if [ $yes = 0 ] && [ $merge = 0 ]; then
      echo "Plan only, for ${#repos[@]} repos. Ask the user, then rerun with the same --repo flags and --yes."
      exit 2
    fi
    flags=(); [ $yes = 0 ] || flags+=(--yes); [ $merge = 0 ] || flags+=(--merge)
    urls=() failed=''
    for r in "${repos[@]}"; do
      echo "== $r: ${flags[*]} =="
      tmp=$(mktemp "${TMPDIR:-/tmp}/rexc-ff.XXXXXX")
      rc=0; "$0" --repo "$r" ${fwd[@]+"${fwd[@]}"} "${flags[@]}" 2>&1 | tee "$tmp" || rc=$? # pipefail: the run's exit
      u=$(grep -Eo "$FORGE_PR_RE" "$tmp" | tail -n1 || true)
      rm -f "$tmp"; echo
      if [ "$rc" = 0 ] && [ -n "$u" ]; then urls+=("$r $u"); else failed+=" $r"; fi
    done
    # Cross-link the PRs: "Part of: <the others>" in each body, replacing an older such line.
    if [ $merge = 0 ] && [ ${#urls[@]} -gt 1 ]; then
      for ru in "${urls[@]}"; do
        u=${ru#* }; others=''
        for o in "${urls[@]}"; do [ "${o#* }" = "$u" ] || others+="${others:+ }${o#* }"; done
        forge_pr_use "$u" # its forge, from the URL
        body=$(forge_pr_body "$u") \
          || { echo "rex-coordinator: could not read the body of $u: no Part of line" >&2; continue; }
        tmp=$(mktemp "${TMPDIR:-/tmp}/rexc-pr.XXXXXX")
        printf '%s\n' "$body" | awk -v line="Part of: $others" '
          /^Part of: / { next }
          !done && index($0, "🤖 Generated with") == 1 { print line; print ""; done = 1 }
          { print } END { if (!done) { print ""; print line } }' > "$tmp"
        forge_pr_edit_body "$u" "$tmp" >/dev/null 2>&1 \
          || echo "rex-coordinator: could not edit the body of $u: no Part of line" >&2
        rm -f "$tmp"
      done
    fi
    echo "Summary ($([ $merge = 1 ] && echo merged || echo pull requests)):"
    for ru in ${urls[@]+"${urls[@]}"}; do echo "  ${ru%% *}: ${ru#* }"; done
    [ -z "$failed" ] || { echo "  failed:$failed (see above)"; exit 1; }
    if [ $merge = 0 ]; then
      echo "Watch their checks in the background, one each: $(dirname "$0")/pr-watch.sh <url>"
    fi
    exit 0
  fi
  wsrepo=${repos[0]}; root="$ws/$wsrepo"
else
  [ ${#repos[@]} = 0 ] || die "--repo is for workspace mode only: this coordinator covers one repo"
  root=$(repo_root)
fi
where="the main checkout"; [ -z "$wsrepo" ] || where="$wsrepo's main checkout"
attribution=$ATTRIBUTION
problems=() warnings=()
problem() { problems+=("$*"); }
warning() { warnings+=("$*"); }

# --- what to wrap up -------------------------------------------------------
resolve_feature ${wsrepo:+"$wsrepo"} || true
feature=$FEATURE
if [ -z "$(checkout_branch "$root")" ]; then
  problem "$where ($root) is not on a branch (detached HEAD or rebase in progress): check out the feature branch"
  feature=
fi
[ -z "$FEATURE_NOTE" ] || echo "rex-coordinator: $FEATURE_NOTE" >&2
busy=$(checkout_busy "$root")
[ -z "$busy" ] || problem "$where has $busy in progress: finish it first"
! checkout_dirty "$root" || problem "$where ($root) has uncommitted changes: commit or stash them first"

if [ -z "$target" ]; then
  target=$(default_target "$root")
fi
[ -z "$feature" ] || [ "$feature" != "$target" ] \
  || problem "$where is on $target, the target itself: check out the feature branch (or pass --into <target>)"
if [ -n "$feature" ]; then
  on=$(tasks_based_on ${wsrepo:+"$wsrepo"} "$feature")
  [ -z "$on" ] || problem "open tasks are based on $feature: $on (merge and finish them, or abandon them, first)"
fi

# --- the forge (GitHub or Azure DevOps) -----------------------------------------
forge_check "$root" "${wsrepo:-this repo}"
for p in ${FORGE_PROBLEMS[@]+"${FORGE_PROBLEMS[@]}"}; do problem "$p"; done
repo=$FORGE_REPO forge=$FORGE
url=$(git -C "$root" config --get remote.origin.url 2>/dev/null || true)

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
    # Workspace mode: only this repo's lines ("<repo>/<slug>"), shown without the repo.
    if [ -n "$wsrepo" ]; then
      case $slug in "$wsrepo"/*) slug=${slug#"$wsrepo"/} ;; *) continue ;; esac
    fi
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
prf=''; [ -z "$feature" ] || prf=$(feature_pr_file "$feature" "$wsrepo")
pr_url='' pr_num=''
if [ ${#problems[@]} = 0 ]; then
  open=$(forge_pr_find "$feature" "$target") \
    || die "could not list the PRs of $repo on $(forge_name) (head $feature)"
  read -r pr_url pr_num <<<"$open" || true
fi

record_pr() { # record_pr <url> <number>
  local created; created=$(kv_get "$prf" created); created=${created:-$(date +%F)}
  mkdir -p "$(dirname "$prf")"
  printf 'feature=%s\ntarget=%s\nurl=%s\nnumber=%s\nforge=%s\nrepo=%s\ncreated=%s\n' \
    "$feature" "$target" "$1" "$2" "$forge" "$repo" "$created" > "$prf.tmp.$$" \
    && { [ -z "$wsrepo" ] || echo "ws_repo=$wsrepo" >> "$prf.tmp.$$"; } && mv -f "$prf.tmp.$$" "$prf"
}
ledger() { echo "- $(date +%F) ${wsrepo:+$wsrepo/}$feature pr #$1 — $2 | pr: $3" >> "$dir/history.md" 2>/dev/null || true; }

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
  forge_pr_merge "$pr_url" || die "merging $pr_url on $(forge_name) failed"
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

[ -z "$wsrepo" ] || echo "Repo:     $wsrepo ($root)"
echo "Feature:  $feature ($ahead commit$([ "$ahead" = 1 ] || echo s) ahead of origin/$target)"
echo "Target:   $target on $repo$([ "$forge" = github ] || echo " ($(forge_name))")"
if [ -n "$pr_url" ]; then echo "PR:       reuse #$pr_num $pr_url"
else echo "PR:       new, title: $title"; fi
echo "Tasks:    ${n_tasks:-0} merged${slugs:+ (${slugs% })}"
[ -z "$excluded" ] || echo "Abandoned on this branch (listed under Not included): $(printf '%s' "$excluded" | sed -E 's/^- ([^ ]+).*/\1/' | paste -sd' ' -)"
for w in ${warnings[@]+"${warnings[@]}"}; do echo "Warning:  $w"; done
if [ $yes = 0 ]; then
  echo
  echo "Not pushed. Would run: git push -u origin $feature, then $(if [ -n "$pr_url" ]; then echo "reuse #$pr_num"; else forge_pr_create_hint "$target" "$feature"; fi)."
  echo "Ask the user, then rerun with --yes$([ ${#warnings[@]} = 0 ] || echo " (it also accepts the warnings above)")."
  if [ -z "$pr_url" ]; then echo; echo "PR body:"; printf '%s\n' "$body" | sed 's/^/  | /'; fi
  exit 2
fi

git -C "$root" push -u origin "$feature" || die "git push -u origin $feature failed"
if [ -z "$pr_url" ]; then
  tmp=$(mktemp "${TMPDIR:-/tmp}/rexc-pr.XXXXXX"); trap 'rm -f "$tmp"' EXIT
  printf '%s\n' "$body" > "$tmp"
  pr_url=$(forge_pr_create "$target" "$feature" "$title" "$tmp") || die "no PR was created"
  pr_num=$(forge_pr_id "$pr_url")
  record_pr "$pr_url" "$pr_num"
  ledger "$pr_num" "$title" "$pr_url"
  echo "Created PR #$pr_num: $pr_url"
else
  record_pr "$pr_url" "$pr_num"
  echo "Pushed $feature; reusing PR #$pr_num: $pr_url"
fi
echo "Watch its checks in the background: $(dirname "$0")/pr-watch.sh $pr_url"
echo "$pr_url"
