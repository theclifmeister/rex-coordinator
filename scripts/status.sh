#!/usr/bin/env bash
# status.sh — the feature branch (the main checkout's branch, and a note when
# it changed since last seen), coordinator state, open tasks, reports waiting, research tabs
# (with the ref@sha, or the sha, they read), worktrees, and
# this repo's tsk board (tsk list -p <root> --json) with each task's linked
# slug, its steps progress (steps done/total) and drift flags (!): worker
# gone but task started, blocked with a reply, review sent back, open task
# with no board task.
# Workspace mode: a "Repos:" block instead of the feature branch (one line per
# repo; repos on their default branch with no tasks folded into one line),
# each task's repo, worktrees of the repos that have tasks, and the board of
# the workspace folder and its repos (tsk list --all --json, filtered by path).
source "$(dirname "$0")/lib.sh"
dir=$(state_dir); _STATE_DIR=$dir
if [ ! -f "$dir/state" ]; then echo "No coordinator set for this repo."; exit 0; fi
ws=; feats=
if ws=$(ws_root); then
  root=$ws; feature=
  echo "Workspace:         $ws"
  echo "Repos:"
  folded='' notes=''
  for r in $(ws_repos "$ws"); do
    resolve_feature "$r" || true
    feats+="$r $FEATURE"$'\n'
    open=$(open_task_slugs "$r" | tr '\n' ' '); open=${open% }
    def=$(repo_default_branch "$ws/$r")
    flag=; [ -z "$FEATURE_NOTE" ] || flag="  (!) changed from $FEATURE_LAST"
    if [ -z "$open" ] && [ -z "$FEATURE_NOTE" ] && [ -z "$FEATURE_WARN" ] && [ -n "$FEATURE" ] && [ "$FEATURE" = "$def" ]; then
      folded+="${folded:+, }$r"; continue
    fi
    sha=$(git -C "$ws/$r" rev-parse --short "${FEATURE:-HEAD}" 2>/dev/null || echo '?')
    echo "  $r  ${FEATURE:-no branch} @ $sha${open:+  open: $open}$flag"
    [ -z "$FEATURE_WARN" ] || notes+="  (!) $r: $FEATURE_WARN"$'\n'
    case $FEATURE_NOTE in *"open tasks still based"*) notes+="  (!) $FEATURE_NOTE"$'\n' ;; esac
  done
  [ -z "$folded" ] || echo "  on their default branch, no tasks: $folded"
  printf '%s' "$notes"
else
root=$(repo_root)
resolve_feature || true; feature=$FEATURE
if [ -n "$feature" ]; then
  src="the main checkout's branch"; [ -z "$FEATURE_WARN" ] || src="last seen"
  echo "Feature branch:    $feature @ $(git -C "$root" rev-parse --short "$feature" 2>/dev/null || echo '?')  ($src)"
else
  echo "Feature branch:    none"
fi
[ -z "$FEATURE_WARN" ] || echo "  (!) $FEATURE_WARN"
[ -z "$FEATURE_NOTE" ] || echo "  (!) $FEATURE_NOTE"
fi
echo "Coordinator block: $(state_get block)"
[ "$(state_get block)" = "${REX_BLOCK:-}" ] && echo "  (this pane)" || echo "  (NOT this pane: ${REX_BLOCK:-none})"
echo "State:             $dir"
echo
echo "Open tasks:"
found=0
for f in "$dir"/tasks/*.block; do
  [ -e "$f" ] || continue; found=1
  slug=$(basename "$f" .block); block=$(cat "$f")
  alive=gone; rex block inspect "$block" >/dev/null 2>&1 && alive=open
  report=-; case $slug in research-*) ;; *) [ -f "$(state_file report "$slug")" ] && report="report ready" ;; esac
  case $slug in
    research-*)
      t=${slug#research-}; report=-; [ -s "$(state_file research "$t")" ] && report="answer ready"
      at=$(research_reads "$dir/tasks/$slug.ref")
      echo "  $slug  tab=$block ($alive)  reads=${at:-?}  $report" ;;
    *)
      base=$(task_base "$slug")
      troot=$root repo='' rf=$feature
      if [ -n "$ws" ]; then
        repo=$(task_repo "$slug"); troot="$ws/${repo:-?}"
        rf=$(awk -v r="$repo" '$1 == r { print $2; exit }' <<<"$feats")
      fi
      ahead=$(git -C "$troot" rev-list --count "$base..$slug" 2>/dev/null || echo "?")
      board=$(tsk_link "$slug" | cut -d' ' -f2)
      where="the main checkout"; [ -z "$repo" ] || where="$repo's main checkout"
      other=; [ -z "$rf" ] || [ "$base" = "$rf" ] \
        || other="  (!) base is not the feature branch: merge it with $where on $base"
      echo "  $slug  ${ws:+repo=${repo:-? (!)}  }tab=$block ($alive)  base=${base:-?}  commits=$ahead  $report  board=${board:-none (!)}$other" ;;
  esac
done
[ $found = 1 ] || echo "  none"
prs=
for f in "$dir"/features/*.pr; do
  [ -f "$f" ] && [ -z "$(kv_get "$f" merged)" ] || continue
  prs+="  $(kv_get "$f" feature) -> $(kv_get "$f" target)  #$(kv_get "$f" number) $(kv_get "$f" url)  (since $(kv_get "$f" created))"$'\n'
done
if [ -n "$prs" ]; then echo; echo "Feature PRs (open; finish-feature.sh --merge merges, on the user's say-so):"; printf '%s' "$prs"; fi
echo
if [ -n "$ws" ]; then
  # Only the repos that have tasks: nine worktree lists would be noise.
  wrepos=$(for f in "$dir"/tasks/*.repo; do [ -f "$f" ] && head -n1 "$f"; done | sort -u)
  echo "Worktrees:"
  if [ -z "$wrepos" ]; then echo "  no tasks in any repo"; fi
  for r in $wrepos; do
    echo "  $r:"; git -C "$ws/$r" worktree list 2>/dev/null | sed 's/^/    /' || true
  done
else
  echo "Worktrees:"; git -C "$root" worktree list | sed 's/^/  /'
fi
echo
echo "tsk board ($root):"
if ! have_tsk; then echo "  tsk not installed"; exit 0; fi
# uuid -> "slug open|review" for every link.
links=
for f in "$dir"/tasks/*.tsk "$dir"/review/*.tsk; do
  [ -f "$f" ] || continue
  kind=open; case $f in "$dir"/review/*) kind=review ;; esac
  links+="$(cut -d' ' -f1 < "$f" | head -n1) $(basename "$f" .tsk) $kind"$'\n'
done
steps() { # steps <task-json>: "  steps <done>/<total>" when it has steps (0.14 rows carry the counts)
  jq -r '((.steps_total // ((.steps // []) | length)) | tonumber? // 0) as $t
    | ((.steps_done // ([(.steps // [])[] | select(.done)] | length)) | tonumber? // 0) as $d
    | if $t > 0 then "  steps \($d)/\($t)" else "" end' <<<"$1" 2>/dev/null || true
}
label() { if [ "$2" = review ]; then echo "[$1, merged]"; else echo "[$1]"; fi; }
flag() { # flag <task-json> <slug> <kind>: drift notes for one linked task
  local t=$1 slug=$2 kind=$3 st
  st=$(jq -r .status <<<"$t")
  if [ "$kind" = open ]; then
    if [ "$st" = started ] && { [ ! -f "$dir/tasks/$slug.block" ] \
        || ! rex block inspect "$(cat "$dir/tasks/$slug.block")" >/dev/null 2>&1; }; then
      printf '  (!) started but no live worker tab'
    fi
    [ "$st" = blocked ] && [ "$(jq '(.block.replies // []) | length' <<<"$t")" -gt 0 ] \
      && printf '  (!) blocked, has a reply: %s' "$(jq -r '.block.replies[-1].text' <<<"$t" | one_line 80)"
  else
    [ "$st" != review ] && [ "$(jq -r '.past_reviews[-1].resolution // ""' <<<"$t")" = sent_back ] \
      && printf '  (!) review sent back: %s' "$(jq -r '[(.past_reviews[-1].feedback // [])[].text] | join(" / ")' <<<"$t" | one_line 80)"
    [ "$st" = "done" ] && printf '  (!) closed by the user (board-watch.sh drops the link)'
  fi
  return 0
}
rc=0
if [ -n "$ws" ]; then
  # The workspace folder's project and its repos' own projects, in one read.
  rows=$(tsk list --all --json 2>&1) || rc=$?
  [ $rc != 0 ] || rows=$(jq -c --arg ws "$ws" '[.[] | select((.project // "") as $p | $p == $ws or ($p | startswith($ws + "/")))]' <<<"$rows" 2>&1) || rc=$?
else
  rows=$(tsk list -p "$root" --json 2>&1) || rc=$?
fi
if [ $rc != 0 ] || ! jq -e 'type == "array"' <<<"$rows" >/dev/null 2>&1; then
  echo "  could not read the board (exit $rc): $rows" | head -n3
  rows='[]'
fi
listed=
while IFS=$'\x1f' read -r id num st on title; do
  [ -n "$id" ] || continue
  listed+="$id"$'\n'
  link=$(grep "^$id " <<<"$links" | head -n1 || true)
  extra=
  if [ -n "$link" ]; then
    read -r _ lslug kind <<<"$link"
    # List rows leave out past reviews and replies: read the linked task in full.
    t=$(tsk_task "$id") || t=$(jq -c --arg id "$id" '.[] | select(.id == $id)' <<<"$rows")
    extra="  $(label "$lslug" "$kind")$(steps "$t")$(flag "$t" "$lslug" "$kind")"
  fi
  echo "  T$num $st${on:+ (on $on)} $title$extra"
done < <(jq -r '.[] | [.id, (.number|tostring), .status, (.block.on // .review.on // ""), .title] | join("\u001f")' <<<"$rows")
if [ -z "$listed" ]; then
  if [ -n "$ws" ]; then echo "  no live tasks for this workspace or its repos (tsk list --all --json shows every project)"
  else echo "  no live tasks for this repo (tsk list --all --json shows every project)"; fi
fi
# Linked tasks the live list leaves out (done, archived, elsewhere).
while read -r id lslug kind; do
  [ -n "$id" ] || continue
  grep -qxF "$id" <<<"$listed" && continue
  if t=$(tsk_task "$id"); then
    echo "  T$(jq -r .number <<<"$t") $(jq -r .status <<<"$t") $(jq -r .title <<<"$t")  $(label "$lslug" "$kind")$(steps "$t")$(flag "$t" "$lslug" "$kind")"
  else
    echo "  ? $id  [$lslug] (!) linked task not readable"
  fi
done <<<"$links"
