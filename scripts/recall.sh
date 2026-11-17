#!/usr/bin/env bash
# recall.sh <word> [word...] — read-only, case-insensitive search of the
# coordinator's memory: history.md, briefs/, reports/, research/.
# Prints matching ledger lines, then files ranked by how many words they hold.
source "$(dirname "$0")/lib.sh"
[ $# -gt 0 ] || die "usage: recall.sh <word> [word...]"
for w in "$@"; do [ -n "$w" ] || die "usage: recall.sh <word> [word...] (empty word)"; done
dir=$(state_dir)
[ -d "$dir" ] || { echo "No coordinator state for this repo ($dir)."; exit 0; }

args=(); for w in "$@"; do args+=(-e "$w"); done
found=0

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

[ $found = 1 ] || echo "Nothing matches: $* (searched $dir)."
