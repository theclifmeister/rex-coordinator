# shellcheck shell=bash
# Where a repo's coordinator state lives. Sourced by lib.sh and by
# hooks-handlers/session-start.sh; defines functions only, writes nothing.
#
# State is per repo, outside the repo: ~/.rex-coordinator/<name>-<hash>, where
# <name> is the main checkout's folder name and <hash> the first 8 hex digits
# of the SHA-256 of its physical path. Older versions kept it in
# <git-common-dir>/rex-coordinator (state_legacy_dir); lib.sh's state_dir
# moves that over once and leaves a symlink behind.

state_home() { echo "${REX_COORDINATOR_HOME:-$HOME/.rex-coordinator}"; }

# state_path_for <git-common-dir (absolute)>
state_path_for() {
  local main hash
  main=$(dirname "$1")
  main=$( (cd "$main" 2>/dev/null && pwd -P) || echo "$main")
  hash=$(printf '%s' "$main" | { shasum -a 256 2>/dev/null || sha256sum 2>/dev/null || cksum; } | cut -c1-8)
  echo "$(state_home)/$(basename "$main")-$hash"
}

state_legacy_dir() { echo "$1/rex-coordinator"; } # state_legacy_dir <git-common-dir>
