# shellcheck shell=bash
# Where a coordinator's state lives. Sourced by lib.sh and by
# hooks-handlers/session-start.sh; defines functions only, writes nothing.
#
# State is per repo (or per workspace folder), outside the repo:
# ~/.rex-coordinator/<name>-<hash>, where <name> is the main checkout's (or
# workspace folder's) name and <hash> the first 8 hex digits of the SHA-256 of
# its physical path. Older versions kept a repo's state in
# <git-common-dir>/rex-coordinator (state_legacy_dir); lib.sh's state_dir
# moves that over once and leaves a symlink behind.

state_home() { echo "${REX_COORDINATOR_HOME:-$HOME/.rex-coordinator}"; }

# state_path_for_dir <dir>: the state dir keyed by that folder (a main
# checkout, or a workspace folder that holds several repos)
state_path_for_dir() {
  local main hash
  main=$( (cd "$1" 2>/dev/null && pwd -P) || echo "$1")
  hash=$(printf '%s' "$main" | { shasum -a 256 2>/dev/null || sha256sum 2>/dev/null || cksum; } | cut -c1-8)
  echo "$(state_home)/$(basename "$main")-$hash"
}

# state_path_for <git-common-dir (absolute)>: a repo's state dir, keyed by its main checkout
state_path_for() { state_path_for_dir "$(dirname "$1")"; }

state_legacy_dir() { echo "$1/rex-coordinator"; } # state_legacy_dir <git-common-dir>

# ws_state_walk <dir> [<block>]: the state dir of the nearest workspace at or
# above <dir> (a folder whose state has mode=workspace) and, given a block,
# whose block= is that block. Nothing if there is none. Only folders whose
# name has some state dir are hashed, so this stays cheap.
ws_state_walk() {
  local d f sd hit
  d=$(cd "$1" 2>/dev/null && pwd -P) || return 0
  while [ -n "$d" ] && [ "$d" != / ]; do
    hit=
    for f in "$(state_home)/${d##*/}"-*/state; do [ -f "$f" ] && { hit=1; break; }; done
    if [ -n "$hit" ]; then
      sd=$(state_path_for_dir "$d")
      if [ -f "$sd/state" ] && grep -qx 'mode=workspace' "$sd/state" 2>/dev/null \
         && { [ -z "${2:-}" ] || grep -qxF "block=$2" "$sd/state" 2>/dev/null; }; then
        echo "$sd"; return 0
      fi
    fi
    d=${d%/*}
  done
  return 0
}
