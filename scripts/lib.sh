# Shared helpers for rex-coordinator scripts. Source, don't run.
set -euo pipefail

die() { echo "rex-coordinator: $*" >&2; exit 1; }

# Per-repo state lives inside the git common dir, so it is shared by every
# worktree, never committed, and needs no .gitignore entry.
state_dir() {
  local common
  common=$(git rev-parse --path-format=absolute --git-common-dir 2>/dev/null) \
    || die "not inside a git repository"
  echo "$common/rex-coordinator"
}

state_get() { # state_get <key>
  local f
  f="$(state_dir)/state"
  [ -f "$f" ] || return 0
  sed -n "s/^$1=//p" "$f" | head -n1
}

repo_root() { # main checkout, even when called from a worktree
  dirname "$(git rev-parse --path-format=absolute --git-common-dir)"
}

require_coordinator() {
  [ "${CLAUDE_ROLE:-}" != worker ] || die "CLAUDE_ROLE=worker: workers don't coordinate"
  [ -n "${REX_BLOCK:-}" ] || die "REX_BLOCK is not set: not running in a Rex pane"
  [ -f "$(state_dir)/state" ] || die "no coordinator set for this repo (run /coordinator-start)"
  [ "$(state_get block)" = "$REX_BLOCK" ] \
    || die "this pane ($REX_BLOCK) is not the coordinator ($(state_get block))"
}

check_slug() {
  [[ "${1:-}" =~ ^[a-z0-9][a-z0-9._-]*$ ]] || die "slug must be lowercase letters, digits, . _ - (got '${1:-}')"
}
