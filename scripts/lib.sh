# shellcheck shell=bash
# Shared helpers for rex-coordinator scripts. Source, don't run.
set -euo pipefail

die() { echo "rex-coordinator: $*" >&2; exit 1; }

# shellcheck source=state-path.sh
source "$(dirname "${BASH_SOURCE[0]}")/state-path.sh"

# Per-repo state lives in ~/.rex-coordinator/<name>-<hash> (state-path.sh),
# keyed by the main checkout, so every worktree shares it and it is never in
# the repo. State still in the old <git-common-dir>/rex-coordinator is moved
# there on first use; a symlink stays at the old path, so workers briefed
# with old paths and absolute paths in older history lines keep working.
state_dir() {
  local common dir old
  common=$(git rev-parse --path-format=absolute --git-common-dir 2>/dev/null) \
    || die "not inside a git repository"
  dir=$(state_path_for "$common")
  old=$(state_legacy_dir "$common")
  if [ -d "$old" ] && [ ! -L "$old" ] && [ ! -e "$dir" ]; then
    mkdir -p "$(dirname "$dir")" && mv "$old" "$dir" && ln -s "$dir" "$old" \
      && echo "rex-coordinator: moved this repo's state from $old to $dir" >&2
  fi
  echo "$dir"
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

state_set() { # state_set <key> <value>: replace (or add) one line of the state file
  local f; f="$(state_dir)/state"
  [ -f "$f" ] || return 0
  awk -v k="$1" -v v="$2" 'index($0, k "=") == 1 { if (!d) print k "=" v; d = 1; next }
    { print } END { if (!d) print k "=" v }' "$f" > "$f.tmp.$$" && mv -f "$f.tmp.$$" "$f"
}

# --- the feature branch ---------------------------------------------------
# The feature branch is whatever branch the main checkout has checked out:
# switching is a plain `git checkout`. state's feature= is the last one seen,
# so a switch is noticed (and reported) once. Each task keeps the branch it was
# cut from in tasks/<slug>.base; tasks from before that file existed use
# state's feature=, which is why a switch pins it into their .base first.

checkout_branch() { # the main checkout's branch; nothing if detached, mid-rebase or unborn
  local root b; root=$(repo_root)
  b=$(git -C "$root" symbolic-ref --short -q HEAD 2>/dev/null) || return 0
  git -C "$root" rev-parse --verify -q "refs/heads/$b" >/dev/null || return 0
  echo "$b"
}

open_task_slugs() { # slugs of open (non-research) tasks, one per line
  local d f s; d="$(state_dir)/tasks"
  for f in "$d"/*.block "$d"/*.tsk "$d"/*.base; do
    [ -f "$f" ] || continue
    s=$(basename "$f"); s=${s%.*}
    case $s in research-*) continue ;; esac
    echo "$s"
  done | sort -u
}

task_base() { # task_base <slug>: the branch the task was cut from (and merges into)
  local f; f="$(state_dir)/tasks/$1.base"
  if [ -s "$f" ]; then head -n1 "$f"; else state_get feature; fi
}

tasks_based_on() { # tasks_based_on <branch>: open task slugs whose base is <branch>, space-separated
  local s out=
  for s in $(open_task_slugs); do [ "$(task_base "$s")" = "$1" ] && out+=" $s"; done
  echo "${out# }"
}

feature_change_note() { # feature_change_note <old> <new>
  local on; on=$(tasks_based_on "$1")
  printf 'feature branch changed from %s to %s' "$1" "$2"
  if [ -n "$on" ]; then
    printf '; open tasks still based on %s: %s (merge each with the main checkout on %s)\n' "$1" "$on" "$1"
  else printf '\n'; fi
}

# resolve_feature: sets FEATURE (the current feature branch), FEATURE_NOTE (the
# change note, when the coordinator sees a new branch for the first time) and
# FEATURE_WARN (when the main checkout is on no branch and the last seen one
# is used). Run in the coordinator pane, it records a new branch as last seen,
# after pinning tasks without a .base to the old one. Returns 1 if there is
# no branch at all.
FEATURE='' FEATURE_NOTE='' FEATURE_WARN=''
resolve_feature() {
  local cur last s d
  FEATURE='' FEATURE_NOTE='' FEATURE_WARN=''
  cur=$(checkout_branch); last=$(state_get feature)
  if [ -z "$cur" ]; then
    [ -n "$last" ] || { FEATURE_WARN="the main checkout is on no branch (detached HEAD or rebase in progress) and no feature branch was recorded"; return 1; }
    FEATURE=$last
    FEATURE_WARN="the main checkout is on no branch (detached HEAD or rebase in progress): using the last feature branch, $last"
    return 0
  fi
  FEATURE=$cur
  if [ -n "$last" ] && [ "$cur" != "$last" ]; then
    FEATURE_NOTE=$(feature_change_note "$last" "$cur")
  fi
  if [ "$cur" != "$last" ] && [ "${CLAUDE_ROLE:-}" != worker ] \
     && [ -n "${REX_BLOCK:-}" ] && [ "$(state_get block)" = "$REX_BLOCK" ]; then
    d="$(state_dir)/tasks"
    if [ -n "$last" ]; then
      for s in $(open_task_slugs); do [ -s "$d/$s.base" ] || echo "$last" > "$d/$s.base"; done
    fi
    state_set feature "$cur"
  fi
  return 0
}

feature_branch() { # the current feature branch on stdout; warning and change note on stderr
  resolve_feature || { echo "rex-coordinator: $FEATURE_WARN" >&2; return 1; }
  [ -z "$FEATURE_WARN" ] || echo "rex-coordinator: $FEATURE_WARN" >&2
  [ -z "$FEATURE_NOTE" ] || echo "rex-coordinator: $FEATURE_NOTE" >&2
  echo "$FEATURE"
}

check_slug() {
  [[ "${1:-}" =~ ^[a-z0-9][a-z0-9._-]*$ ]] || die "slug must be lowercase letters, digits, . _ - (got '${1:-}')"
}

# --- tsk board --------------------------------------------------------------
# doctor.sh requires tsk >= 0.14.1 at activation, but every board call stays
# best-effort: skipped when tsk is not (or no longer) installed, and a
# failure only warns (to stderr), never fails the git/Rex work. Project-scoped
# calls always pass -p "$(repo_root)"; starts always pass --no-dispatch.
# A coordinator task's board link is tasks/<slug>.tsk while it is open, and
# review/<slug>.tsk after merge until the user closes it. Line 1 of a link file
# is "<uuid> T<n>"; board-watch.sh may add a "seen=<key>" line.

have_tsk() { command -v tsk >/dev/null 2>&1; }

# --- Rex layout of the coordinator's tab (start.sh, stop.sh) ---------------
# Best-effort: a Rex failure only warns. Blocks are closed only by the ID we
# recorded (state's tsk_block=), never by label or pattern.
rex_warn() { echo "rex-coordinator: warning: $*" >&2; }

rex_block_window() { # rex_block_window <session> <block>: its window ID, empty if it is gone
  [ -n "$1" ] && [ -n "$2" ] || return 0
  rex block inspect -s "$1" "$2" --json 2>/dev/null | jq -r '.block.window_id // empty' 2>/dev/null || true
}

rex_window_label() { # rex_window_label <session> <window>
  rex window inspect -s "$1" "$2" --json 2>/dev/null | jq -r '.label // empty' 2>/dev/null || true
}

rex_restore_tab() { # rex_restore_tab <session> <window> <label>: undo our rename, if it is still ours
  [ -n "$2" ] && [ -n "$3" ] || return 0
  [ "$(rex_window_label "$1" "$2")" = coordinator ] || return 0
  rex window rename -s "$1" "$2" "$3" >/dev/null 2>&1 || rex_warn "could not rename tab $2 back to '$3'"
}

rex_close_board() { # rex_close_board <session> <block>: close the tsk pane we opened, if it still exists
  [ -n "$(rex_block_window "$1" "$2")" ] || return 0
  rex block close -s "$1" "$2" >/dev/null 2>&1 || rex_warn "could not close the tsk pane $2"
}

tsk_warn() { echo "rex-coordinator: tsk: $*" >&2; }

TSK_RC=0
# shellcheck disable=SC2034 # TSK_RC is read by the scripts that source this
tsk_try() { # tsk_try <args...>: run tsk, warn on failure, always return 0; tsk's exit is in $TSK_RC
  TSK_RC=127; have_tsk || return 0
  local out rc=0
  out=$(tsk "$@" 2>&1) || rc=$?
  TSK_RC=$rc
  case $rc in
    0) [ -z "$out" ] || printf 'board: %s\n' "$out" >&2 ;;
    3) tsk_warn "indeterminate (exit 3) on 'tsk $1 ${2:-}': $out — verify with: tsk list ${2:-<task>} --json" ;;
    *) tsk_warn "'tsk $1 ${2:-}' failed (exit $rc): $out" ;;
  esac
  return 0
}

tsk_task() { # tsk_task <task>: that task's JSON object, or return 1
  have_tsk || return 1
  local out
  out=$(tsk list "$1" --json 2>/dev/null) || return 1
  out=$(jq -ce '.[0] // empty' <<<"$out" 2>/dev/null) || return 1
  printf '%s\n' "$out"
}

tsk_link_file() { # tsk_link_file <slug>: path of its link file, or return 1
  local d; d=$(state_dir)
  if [ -f "$d/tasks/$1.tsk" ]; then echo "$d/tasks/$1.tsk"
  elif [ -f "$d/review/$1.tsk" ]; then echo "$d/review/$1.tsk"
  else return 1; fi
}

tsk_link() { # tsk_link <slug>: "<uuid> T<n>" of its linked board task, or nothing
  local f; f=$(tsk_link_file "$1") || return 0
  head -n1 "$f"
}

thread_name() { # thread_name <branch>: a tsk thread name for it (letters, digits, - and .)
  printf '%s' "$1" | tr -c 'A-Za-z0-9.-' '-' | tr -s '-' | sed 's/^[-.]*//; s/[-.]*$//'
}

# tsk_set_thread <uuid> <branch>: put a linked task on the branch's thread,
# unless it already has one (the user's choice wins). Best-effort: tsk older
# than 0.14.1 has no `edit --thread`, and only a note says so.
tsk_set_thread() {
  have_tsk || return 0
  local t cur name out rc=0
  name=$(thread_name "$2"); [ -n "$name" ] || return 0
  t=$(tsk_task "$1") || return 0
  cur=$(jq -r '.thread // ""' <<<"$t")
  [ -z "$cur" ] || return 0
  out=$(tsk edit "$1" --thread "$name" 2>&1) || rc=$?
  case $rc in
    0) ;;
    2) tsk_warn "thread not set (tsk edit --thread needs tsk >= 0.14.1): $(head -n1 <<<"$out" | one_line 120)" ;;
    *) tsk_warn "thread not set (exit $rc): $(one_line 160 <<<"$out")" ;;
  esac
  return 0
}

one_line() { # one_line [max]: stdin squashed to one line, cut to max chars
  tr '\r\n\t' '   ' | tr -s ' ' | sed 's/^ //; s/ $//' | cut -c1-"${1:-200}"
}

canon_dir() { (cd "$1" 2>/dev/null && pwd -P) || echo "$1"; }

# research_reads <ref-file>: what a research topic read, from its
# "<ref> <short sha>" file: "<branch>@<short>" for a named ref, just "<short>"
# for a commit (older files may hold the full hash as <ref>). Nothing if unreadable.
research_reads() {
  awk 'NR==1 && NF>=2 {
         if ($1 == $2 || ($1 ~ /^[0-9a-f]+$/ && index($1, $2) == 1)) print $2
         else print $1 "@" $2
       }' "$1" 2>/dev/null || true
}

# --- Reports on the board ----------------------------------------------------
# A worker's report (layout in brief-template.md): line 1 "Summary: <one line>",
# then "## Done", "## Checks" (one "- PASS|FAIL|SKIP <text>" line per check),
# "## Not done" and "## Open questions" (bullets, or "none"). finish-task.sh
# mirrors it onto the linked task's review round; board.sh adds checks later.
# A check spec is "PASS|FAIL|SKIP[:] <text>": the check is added open, with
# the result kept in its text ("PASS: <text>"), because the ticks are the
# user's (tsk: checks are the reviewer's). tsk caps each text at 4096 bytes,
# so texts are cut well below that.
REVIEW_MAX_CHECKS=20

report_section() { # report_section <file> <heading>: the lines under "## <heading>", up to the next "## "
  awk -v h="## $2" '{ l = $0; sub(/[[:space:]]+$/, "", l) }
    p && /^## / { exit } p { print } l == h { p = 1 }' "$1" 2>/dev/null || true
}

check_spec() { # check_spec <spec>: "open\t<PASS|FAIL|SKIP>: <text>" (no word: the text as is), nothing for empty text
  local s w
  s=$(printf '%s' "$1" | one_line 100000)
  w=$(sed -nE 's/^(PASS|FAIL|SKIP)(:|[[:space:]]).*/\1/p' <<<"$s")
  if [ -n "$w" ]; then
    s=$(sed -E 's/^(PASS|FAIL|SKIP):?[[:space:]]*//' <<<"$s")
    [ -n "$s" ] || return 0
    s="$w: $s"
  fi
  [ -n "$s" ] || return 0
  printf 'open\t%s\n' "$(one_line 300 <<<"$s")"
}

report_checks() { # report_checks <file>: its "## Checks" as check_spec lines; return 1 if it has none
  local l out=''
  while IFS= read -r l; do
    out+=$(check_spec "$l")$'\n'
  done < <(report_section "$1" Checks | sed -nE 's/^[-*][[:space:]]+((PASS|FAIL|SKIP)(:|[[:space:]]).*)$/\1/p')
  [ -n "$out" ] || return 1
  printf '%s' "$out"
}

report_questions() { # report_questions <file>: its open questions on one line ("; "-joined), nothing for "none"
  local q
  q=$(report_section "$1" "Open questions" | awk '
    /^[[:space:]]*$/ { next }
    /^[[:space:]]*([-*]|[0-9]+\.)[[:space:]]/ { sub(/^[[:space:]]*([-*]|[0-9]+\.)[[:space:]]+/, ""); if (n++) printf "; "; printf "%s", $0; next }
    { sub(/^[[:space:]]+/, ""); printf "%s%s", (n++ ? " " : ""), $0 }' | one_line 1000)
  grep -qiE '^(none|n/a|-)\.?$' <<<"$q" || printf '%s\n' "$q"
}

cap_checks() { # cap_checks [max]: the first max check_spec lines of stdin, then "… N more checks in the report"
  awk -F'\t' -v m="${1:-$REVIEW_MAX_CHECKS}" 'NF >= 2 && $2 != "" { if (++n <= m) print; else more++ }
    END { if (more) printf "open\t… %d more check%s in the report\n", more, (more > 1 ? "s" : "") }'
}

# tsk_review <uuid> <done> <next>: put the task in review on you with the
# "<state>\t<text>" lines on stdin as its checks (in that order; an empty done
# or next leaves the round's own), then set each check whose state differs.
# The plugin's own checks are always open (check_spec); other states are only
# the user's marks, re-passed by board.sh. Repeating it edits the open round,
# and tsk replaces its whole check list: pass every check each time.
tsk_review() {
  local id=$1 st tx i=0 c want cur
  local -a args=(review --on you) states=()
  [ -z "$2" ] || args+=(--done="$2")
  [ -z "$3" ] || args+=(--next="$3")
  while IFS=$'\t' read -r st tx; do
    [ -n "$tx" ] || continue
    args+=(--check="$tx"); states+=("$st")
  done
  have_tsk || return 0
  tsk_try status "$id" "${args[@]}"
  [ "$TSK_RC" = 0 ] && [ ${#states[@]} -gt 0 ] || return 0
  cur=$(tsk_task "$id" | jq -r '.review.checks[]?.state' 2>/dev/null) || cur=
  while IFS= read -r c; do
    [ -n "$c" ] || continue
    i=$((i + 1)); want=${states[$((i - 1))]:-}
    [ -z "$want" ] || [ "$want" = "$c" ] || tsk_try checks "$id" set "$i" "$want"
  done <<<"$cur"
  return 0
}

tsk_note_once() { # tsk_note_once <uuid> <line>: append the line to its notes unless they hold it already
  local t
  t=$(tsk_task "$1") || { tsk_warn "could not read $1: note not added (appending is not safe to repeat blind)"; return 0; }
  grep -qF -- "$2" <<<"$(jq -r '.notes // ""' <<<"$t")" || tsk_try edit "$1" --append-notes="$2"
}

# --- Claude Code's local-scope plugin records -------------------------------
# With the plugin enabled at local scope (the repo's .claude/settings.local.json,
# which Claude Code shares across all the repo's worktrees), every session that
# starts in a worktree adds a local install record for that worktree's path to
# installed_plugins.json. The record outlives the worktree, and a bare
# `claude plugin update` may pick it instead of the user-scope one.

plugin_records_file() { echo "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/plugins/installed_plugins.json"; }

# plugin_local_records: "<plugin id><TAB><projectPath>" for every local-scope
# record of rex-coordinator@<any marketplace>. Nothing without jq or the file.
plugin_local_records() {
  local f; f=$(plugin_records_file)
  [ -f "$f" ] && command -v jq >/dev/null 2>&1 || return 0
  jq -r '.plugins // {} | to_entries[] | select(.key | startswith("rex-coordinator@"))
         | .key as $id | .value[]? | select(.scope == "local" and (.projectPath // "") != "")
         | "\($id)\t\(.projectPath)"' "$f" 2>/dev/null || true
}

# plugin_drop_local_record <path>: remove rex-coordinator's local-scope
# record(s) for <path> (absolute) with `claude plugin uninstall --scope local
# --keep-data` run from <path>: only that path's record goes. A gone path is
# made empty for the call and removed again. That command also drops
# the plugin from the repo's .claude/settings.local.json, so the file is put
# back as it was. Best-effort and silent; does nothing without claude or jq, or
# without such a record. Prints "<id>" per record it removed. Always returns 0.
plugin_drop_local_record() {
  local path=$1 real ids id made='' top common settings='' bak='' existed=0
  command -v claude >/dev/null 2>&1 && command -v jq >/dev/null 2>&1 || return 0
  case $path in /*) ;; *) return 0 ;; esac
  real=$(canon_dir "$path")
  ids=$(plugin_local_records | awk -F'\t' -v p="$path" -v r="$real" '$2 == p || $2 == r {print $1}' | sort -u)
  [ -n "$ids" ] || return 0
  if [ ! -e "$path" ]; then
    top=$path # the topmost directory that has to be made (removed again below)
    while [ ! -e "$(dirname "$top")" ]; do top=$(dirname "$top"); done
    mkdir -p "$path" 2>/dev/null || return 0
    made=$top
  fi
  [ -d "$path" ] || return 0
  # The settings file Claude Code uses for local scope: the main checkout's.
  if common=$(git -C "$path" rev-parse --path-format=absolute --git-common-dir 2>/dev/null); then
    settings="$(dirname "$common")/.claude/settings.local.json"
    if [ -f "$settings" ]; then
      existed=1; bak=$(mktemp "${TMPDIR:-/tmp}/rexc-settings.XXXXXX") && cp -p "$settings" "$bak" || bak=''
    fi
  fi
  for id in $ids; do
    if (cd "$path" && claude plugin uninstall "$id" --scope local --keep-data) </dev/null >/dev/null 2>&1 \
       && ! plugin_local_records | awk -F'\t' -v i="$id" -v p="$path" -v r="$real" \
              '$1 == i && ($2 == p || $2 == r) {f=1} END {exit !f}'; then
      echo "$id"
    fi
  done
  if [ -n "$settings" ]; then
    if [ -n "$bak" ]; then
      cmp -s "$bak" "$settings" 2>/dev/null || cat "$bak" > "$settings" 2>/dev/null || true
      rm -f "$bak"
    elif [ $existed = 0 ] && [ -f "$settings" ] \
         && jq -e '. == {"enabledPlugins": {}}' "$settings" >/dev/null 2>&1; then
      rm -f "$settings" # created by the uninstall, holding nothing
    fi
  fi
  [ -z "$made" ] || rm -rf "$made"
  return 0
}
