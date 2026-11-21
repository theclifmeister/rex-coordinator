#!/usr/bin/env bash
# doctor.sh [--quiet] — check the external tools rex-coordinator needs.
# Required: rex, git (>= 2.31 for --path-format), jq, bash, tsk >= 0.14.1
# (an unparsable tsk version only warns). Notes, never failures: the tsk-cli
# skill not installed, a local-scope plugin enable, and a repo whose origin is
# on GitHub or Azure DevOps without that forge's CLI (gh; az with the
# azure-devops extension), which only the PR features need.
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
# shellcheck source=tsk-version.sh
source "$(dirname "$0")/tsk-version.sh"
tsk_version_check; rc=$?
case $rc in
  1) miss+=("tsk >= $TSK_MIN (not installed: $TSK_FIX)") ;;
  2) miss+=("tsk >= $TSK_MIN (this is ${TSK_VER:-unknown}: $TSK_FIX)") ;;
  3) notes+=("could not read the tsk version from 'tsk --version' (got '${TSK_VER}'); rex-coordinator needs tsk >= $TSK_MIN") ;;
esac
skills=${CLAUDE_CONFIG_DIR:-$HOME/.claude}/skills
[ -f "$skills/tsk-cli/SKILL.md" ] \
  || notes+=("the tsk-cli skill is not installed in $skills: run 'tsk setup' to add it (decline or rebind 'tsk setup rex', which takes alt+t)")
# A local-scope enable (the repo's .claude/settings.local.json, shared by its
# worktrees) makes Claude Code add an install record per worker worktree.
# Outside a git repo (a workspace folder), each repo directly under it.
local_enable_note() { # local_enable_note <main checkout>
  local root=$1 id
  id=$(grep -Eo '"rex-coordinator@[^"]*"[[:space:]]*:[[:space:]]*true' "$root/.claude/settings.local.json" 2>/dev/null \
       | head -n1 | cut -d'"' -f2)
  if [ -n "$id" ]; then
    notes+=("$root/.claude/settings.local.json enables $id at local scope, so Claude Code adds an install record for every worker worktree. With the user-scope install enabled it is not needed: in $root run 'claude plugin uninstall $id --scope local --keep-data' (removes only that enable and the main checkout's local record), then $(cd "$(dirname "$0")" && pwd)/plugin-records.sh --fix for old worktree records")
  fi
}
# The forge CLI the PR features (land-task.sh, finish-feature.sh) would use,
# from origin's URL (lib.sh's forge_parse does it fully; a host match is enough).
# One note per missing CLI. The extension check looks for its folder: az
# itself is slow.
forge_seen=' '
forge_note() { # forge_note <main checkout>
  local url name=${1##*/}
  url=$(git -C "$1" config --get remote.origin.url 2>/dev/null) || return 0
  case $url in
    *github.com[:/]*)
      case $forge_seen in *" gh "*) return 0 ;; esac
      command -v gh >/dev/null 2>&1 && return 0
      forge_seen+="gh "
      notes+=("$name's origin is on GitHub, but gh (the GitHub CLI) is not installed: only needed for PRs (land-task.sh, finish-feature.sh): https://cli.github.com") ;;
    *dev.azure.com[:/]*|*.visualstudio.com[:/]*)
      case $forge_seen in *" az "*) return 0 ;; esac
      forge_seen+="az "
      if ! command -v az >/dev/null 2>&1; then
        notes+=("$name's origin is on Azure DevOps, but az (the Azure CLI) is not installed: only needed for PRs (land-task.sh, finish-feature.sh): https://aka.ms/azure-cli, then az extension add --name azure-devops")
      elif [ ! -d "${AZURE_EXTENSION_DIR:-${AZURE_CONFIG_DIR:-$HOME/.azure}/cliextensions}/azure-devops" ]; then
        notes+=("$name's origin is on Azure DevOps, but az has no azure-devops extension: only needed for PRs (land-task.sh, finish-feature.sh): az extension add --name azure-devops")
      fi ;;
  esac
}
if common=$(git rev-parse --path-format=absolute --git-common-dir 2>/dev/null); then
  local_enable_note "${common%/*}"; forge_note "${common%/*}"
else
  for d in "$PWD"/*/; do d=${d%/}; [ -e "$d/.git" ] && { local_enable_note "$d"; forge_note "$d"; }; done
fi

if [ "$quiet" = 0 ]; then
  for c in rex git jq; do printf '%-4s %s\n' "$c" "$(command -v "$c" 2>/dev/null || echo MISSING)"; done
  printf '%-4s %s%s\n' tsk "$(command -v tsk 2>/dev/null || echo MISSING)" "${TSK_VER:+ ($TSK_VER)}"
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
