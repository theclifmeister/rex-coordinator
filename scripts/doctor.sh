#!/usr/bin/env bash
# doctor.sh [--quiet] — check the external tools rex-coordinator needs.
# Required: rex, git (>= 2.31 for --path-format), jq, bash. Optional: tsk.
# Exit 1 if a required one is missing. Needs nothing but bash itself (no jq).
# --quiet: print only what is missing (to stderr).
set -uo pipefail

quiet=0
case "${1:-}" in --quiet) quiet=1 ;; '') ;; *) echo "usage: $0 [--quiet]" >&2; exit 2 ;; esac

miss=() notes=()
for c in rex git jq; do command -v "$c" >/dev/null 2>&1 || miss+=("$c"); done
[ "${BASH_VERSINFO[0]:-0}" -ge 3 ] || miss+=("bash >= 3 (this is ${BASH_VERSION:-unknown})")
if command -v git >/dev/null 2>&1; then
  gv=$(git --version 2>/dev/null | awk '{print $3}')
  IFS=. read -r gma gmi _ <<<"$gv"
  case "$gma.$gmi" in
    *[!0-9.]*|.*|*.) ;; # unparsable version: don't guess
    *) if [ "$gma" -lt 2 ] || { [ "$gma" -eq 2 ] && [ "$gmi" -lt 31 ]; }; then miss+=("git >= 2.31 (this is $gv)"); fi ;;
  esac
fi
command -v tsk >/dev/null 2>&1 || notes+=("tsk not installed (optional: the board integration is off)")
# A local-scope enable (the repo's .claude/settings.local.json, shared by its
# worktrees) makes Claude Code add an install record per worker worktree.
if common=$(git rev-parse --path-format=absolute --git-common-dir 2>/dev/null); then
  root=${common%/*}
  id=$(grep -Eo '"rex-coordinator@[^"]*"[[:space:]]*:[[:space:]]*true' "$root/.claude/settings.local.json" 2>/dev/null \
       | head -n1 | cut -d'"' -f2)
  if [ -n "$id" ]; then
    notes+=("$root/.claude/settings.local.json enables $id at local scope, so Claude Code adds an install record for every worker worktree. With the user-scope install enabled it is not needed: in $root run 'claude plugin uninstall $id --scope local --keep-data' (removes only that enable and the main checkout's local record), then $(cd "$(dirname "$0")" && pwd)/plugin-records.sh --fix for old worktree records")
  fi
fi

if [ "$quiet" = 0 ]; then
  for c in rex git jq tsk; do printf '%-4s %s\n' "$c" "$(command -v "$c" 2>/dev/null || echo MISSING)"; done
  printf '%-4s %s\n' bash "${BASH_VERSION:-unknown}"
  if [ -n "${REX_BLOCK:-}" ]; then echo "in a Rex pane: $REX_BLOCK"; else echo "not in a Rex pane (REX_BLOCK unset)"; fi
fi
[ ${#notes[@]} -eq 0 ] || printf 'rex-coordinator: note: %s\n' "${notes[@]}" >&2
if [ ${#miss[@]} -gt 0 ]; then
  printf 'rex-coordinator: missing: %s\n' "${miss[@]}" >&2
  exit 1
fi
[ "$quiet" = 1 ] || echo "ok: all required tools found"
exit 0
