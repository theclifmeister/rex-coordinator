#!/usr/bin/env bash
# recall.sh [--board] <word> [word...] — read-only, case-insensitive search of
# the coordinator's memory: history.md, briefs/, reports/, research/.
# Prints matching ledger lines, then files ranked by how many words they hold.
# --board also searches this repo's tsk board tasks (live, done and archived):
# title, notes, steps, blocks and their replies, reviews and their feedback,
# past rounds. Slow: one tsk call per task. Skipped when tsk is not installed.
source "$(dirname "$0")/lib.sh"
usage="usage: recall.sh [--board] <word> [word...]"
board=0 words=()
for w in "$@"; do
  case $w in
    --board) board=1 ;;
    '') die "$usage (empty word)" ;;
    *) words+=("$w") ;;
  esac
done
[ ${#words[@]} -gt 0 ] || die "$usage"
set -- "${words[@]}"
dir=$(state_dir)

args=(); for w in "$@"; do args+=(-e "$w"); done
found=0

if [ ! -d "$dir" ]; then
  echo "No coordinator state for this repo ($dir)."
  [ $board = 1 ] || exit 0
  echo
fi

if [ -f "$dir/history.md" ]; then
  lines=$(grep -iF "${args[@]}" "$dir/history.md" | tail -n 20 || true)
  if [ -n "$lines" ]; then
    found=1; echo "Ledger ($dir/history.md; relative paths are under $dir/):"; printf '%s\n' "$lines" | while IFS= read -r l; do echo "  $l"; done; echo
  fi
fi

# Score each file: number of distinct words it contains.
ranked=$(
  for f in "$dir"/briefs/*.md "$dir"/reports/*.md "$dir"/research/*.md; do
    [ -f "$f" ] || continue
    n=0; for w in "$@"; do grep -qiF -e "$w" "$f" && n=$((n + 1)); done
    if [ $n -gt 0 ]; then printf '%s\t%s\n' "$n" "$f"; fi
  done | sort -t$'\t' -k1,1nr -k2,2 | head -n 10
)
if [ -n "$ranked" ]; then
  found=1; echo "Files (most words matched first, at most 10):"
  while IFS=$'\t' read -r n f; do
    echo "  $f  ($n/$# words)"
    grep -inF "${args[@]}" "$f" | head -n 3 | cut -c1-200 | sed 's/^/      /'
  done <<< "$ranked"
fi

searched=$dir
if [ $board = 1 ]; then
  root=$(repo_root)
  if ! have_tsk; then
    echo "Board: tsk not installed, not searched."
  else
    # Every task of this repo's project: live, done, archived (rows are short;
    # notes, steps, replies and past rounds need one `tsk list <uuid>` each).
    ids=$(for f in "" --done --archived; do
            # shellcheck disable=SC2086 # $f is one flag or nothing
            tsk list -p "$root" $f --json 2>/dev/null || echo '[]'
          done | jq -rs '[.[] | arrays | .[]] | unique_by(.id) | sort_by(.number) | .[].id' 2>/dev/null || true)
    n_ids=$(grep -c . <<<"$ids" || true)
    echo "Board: searching $n_ids board tasks of $root (one tsk call each)…"
    searched+=" and $n_ids board tasks"
    tmp=$(mktemp); trap 'rm -f "$tmp"' EXIT
    for id in $ids; do
      t=$(tsk_task "$id") || continue
      # One labelled line per text; multi-line texts keep their label on each line.
      jq -r '
        def lines($label; $v): ($v // "") | tostring | select(. != "") | split("\n")[] | select(. != "") | "\($label): \(.)";
        lines("title"; .title),
        lines("notes"; .notes),
        (.steps[]? | lines("step"; .text)),
        (.block // empty | lines("block"; .why), lines("block needs"; .needs), (.replies[]? | lines("reply"; .text))),
        (.review // empty | lines("review done"; .done), (.checks[]? | lines("check"; .text)), (.feedback[]? | lines("feedback"; .text))),
        (.past_blocks[]? | lines("past block"; .why), lines("past block needs"; .needs), (.replies[]? | lines("past reply"; .text))),
        (.past_reviews[]? | lines("past review done"; .done), (.feedback[]? | lines("past feedback"; .text)))
      ' <<<"$t" > "$tmp" 2>/dev/null || continue
      n=0; for w in "$@"; do grep -qiF -e "$w" "$tmp" && n=$((n + 1)); done
      [ $n -gt 0 ] || continue
      hdr=$(jq -r '"T\(.number) [\(.status)] \(.title)"' <<<"$t" | one_line 160)
      snip=$(grep -iF "${args[@]}" "$tmp" | head -n 3 | tr '\t' ' ' | cut -c1-200 | sed 's/^/      /')
      printf '%s\t%s\t%s\n' "$n" "$hdr" "$(printf '%s' "$snip" | tr '\n' '\036')"
    done | sort -t$'\t' -k1,1nr -s | head -n 10 > "$tmp.hits"
    if [ -s "$tmp.hits" ]; then
      found=1; echo "Board tasks (most words matched first, at most 10):"
      while IFS=$'\t' read -r n hdr snip; do
        echo "  $hdr  ($n/$# words)"
        printf '%s\n' "$snip" | tr '\036' '\n'
      done < "$tmp.hits"
    fi
    rm -f "$tmp.hits"
  fi
fi

[ $found = 1 ] || echo "Nothing matches: $* (searched $searched)."
