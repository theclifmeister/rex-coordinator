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
repo_state_dir() { # the cwd's git repo's own state dir (single-repo mode)
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

# Workspace mode: one coordinator for a folder that is not a git repo but
# holds git repos as direct children. Its state is keyed by that folder
# (state_path_for_dir) and holds mode=workspace, root=<folder> and
# feature.<repo>=<branch> per repo. state_dir finds it from any cwd under it,
# member repos and their worktrees included:
#  1. a workspace at or above $PWD whose block= is this pane ($REX_BLOCK);
#  2. else the cwd's git repo's own state, when it has one (as before);
#  3. else any workspace at or above $PWD (status.sh, stop.sh run by hand);
#  4. else the git repo's state dir (no state yet), or "not inside a git repository".
# A script may pin the answer in _STATE_DIR (start.sh does: it picks the mode).
_STATE_DIR=
state_dir() {
  local ws dir
  [ -z "$_STATE_DIR" ] || { echo "$_STATE_DIR"; return 0; }
  if [ -n "${REX_BLOCK:-}" ]; then
    ws=$(ws_state_walk "$PWD" "$REX_BLOCK")
    [ -z "$ws" ] || { echo "$ws"; return 0; }
  fi
  if git rev-parse --git-common-dir >/dev/null 2>&1; then
    dir=$(repo_state_dir)
    if [ ! -f "$dir/state" ]; then
      ws=$(ws_state_walk "$PWD")
      [ -z "$ws" ] || { echo "$ws"; return 0; }
    fi
    echo "$dir"; return 0
  fi
  ws=$(ws_state_walk "$PWD")
  [ -n "$ws" ] || die "not inside a git repository"
  echo "$ws"
}

state_get() { # state_get <key>
  local f
  f="$(state_dir)/state"
  [ -f "$f" ] || return 0
  awk -v k="$1" 'index($0, k "=") == 1 { print substr($0, length(k) + 2); exit }' "$f"
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
  return 0
}

state_set() { # state_set <key> <value>: replace (or add) one line of the state file
  local f; f="$(state_dir)/state"
  [ -f "$f" ] || return 0
  awk -v k="$1" -v v="$2" 'index($0, k "=") == 1 { if (!d) print k "=" v; d = 1; next }
    { print } END { if (!d) print k "=" v }' "$f" > "$f.tmp.$$" && mv -f "$f.tmp.$$" "$f"
}

# --- workspace mode -------------------------------------------------------
ws_mode() { [ "$(state_get mode)" = workspace ]; } # true for a workspace coordinator's state

ws_root() { # the workspace folder; return 1 in single-repo mode
  ws_mode || return 1
  state_get root
}

ws_repos() { # ws_repos [<folder>]: names of its depth-1 git repos (a .git dir or file), sorted; default ws_root
  local ws=${1:-} d
  [ -n "$ws" ] || ws=$(ws_root) || return 0
  for d in "$ws"/*/; do
    d=${d%/}
    [ -e "$d/.git" ] && echo "${d##*/}"
  done
  return 0
}

board_project() { # the tsk project for -p: the workspace folder in workspace mode, else the main checkout
  ws_root || repo_root
}

task_repo() { # task_repo <slug|research-topic>: its repo name (tasks/<slug>.repo), or nothing
  head -n1 "$(state_dir)/tasks/$1.repo" 2>/dev/null || true
}

task_root() { # task_root <slug>: the main checkout the task's worktree belongs to
  local r ws
  if ws=$(ws_root); then
    r=$(task_repo "$1")
    [ -n "$r" ] || die "task '$1' has no repo recorded (tasks/$1.repo) in workspace mode"
    echo "$ws/$r"
  else
    repo_root
  fi
}

repo_default_branch() { # repo_default_branch <root>: origin/HEAD's branch, else main or master if present, else nothing
  local b
  b=$(git -C "$1" symbolic-ref --short -q refs/remotes/origin/HEAD 2>/dev/null) && { echo "${b#origin/}"; return 0; }
  for b in main master; do
    git -C "$1" rev-parse --verify -q "refs/heads/$b" >/dev/null 2>&1 && { echo "$b"; return 0; }
  done
  return 0
}

rex_block_alive() { # rex_block_alive <session> <block>: true while that Rex pane exists
  [ -n "$2" ] || return 1
  if [ -n "$1" ]; then rex block inspect -s "$1" "$2" >/dev/null 2>&1
  else rex block inspect "$2" >/dev/null 2>&1; fi
}

# --- workspace tasks (new-task, launch-worker, finish-task, research) ------
# In workspace mode every task and research topic lives in one member repo,
# named with --repo and kept in tasks/<slug>.repo (tasks/research-<topic>.repo):
# its worktree is <ws>/<repo>/.claude/worktrees/<slug> (_research/<topic>).
# Slugs are unique across the workspace, because the state files are flat.

ws_check_repo() { # ws_check_repo <repo>: die unless it is a git repo directly under the workspace
  local r
  [ -n "${1:-}" ] || die "workspace mode ($(ws_root)): name the repo with --repo <name> (one of: $(ws_repos | paste -sd' ' -))"
  for r in $(ws_repos); do [ "$r" = "$1" ] && return 0; done
  die "workspace mode: no git repo '$1' directly under $(ws_root) (repos: $(ws_repos | paste -sd' ' -))"
}

ensure_excluded() { # ensure_excluded <root>: .claude/worktrees/ in that repo's .git/info/exclude
  local ex
  ex="$(git -C "$1" rev-parse --path-format=absolute --git-common-dir)/info/exclude" || return 0
  mkdir -p "$(dirname "$ex")"
  grep -qxF '.claude/worktrees/' "$ex" 2>/dev/null || echo '.claude/worktrees/' >> "$ex"
}

task_label() { # task_label <slug|research-topic> [<name>]: "<repo>/<name>" in workspace mode, else <name> (default: the slug)
  local r; r=$(task_repo "$1")
  if [ -n "$r" ] && ws_mode; then echo "$r/${2:-$1}"; else echo "${2:-$1}"; fi
}

# --- the feature branch ---------------------------------------------------
# The feature branch is whatever branch the main checkout has checked out:
# switching is a plain `git checkout`. state's feature= is the last one seen,
# so a switch is noticed (and reported) once. Each task keeps the branch it was
# cut from in tasks/<slug>.base; tasks from before that file existed use
# state's feature=, which is why a switch pins it into their .base first.
# In workspace mode each repo has its own: feature.<repo>= in state, and the
# functions below take the repo's name (a task always has a .base there).

checkout_branch() { # checkout_branch [<root>]: that main checkout's branch (default: this repo's); nothing if detached, mid-rebase or unborn
  local root=${1:-} b
  [ -n "$root" ] || root=$(repo_root)
  b=$(git -C "$root" symbolic-ref --short -q HEAD 2>/dev/null) || return 0
  git -C "$root" rev-parse --verify -q "refs/heads/$b" >/dev/null || return 0
  echo "$b"
}

open_task_slugs() { # open_task_slugs [<repo>]: slugs of open (non-research) tasks, one per line; only that repo's when given
  local d f s; d="$(state_dir)/tasks"
  for f in "$d"/*.block "$d"/*.tsk "$d"/*.base; do
    [ -f "$f" ] || continue
    s=$(basename "$f"); s=${s%.*}
    case $s in research-*) continue ;; esac
    if [ -n "${1:-}" ] && [ "$(head -n1 "$d/$s.repo" 2>/dev/null)" != "$1" ]; then continue; fi
    echo "$s"
  done | sort -u
}

task_base() { # task_base <slug>: the branch the task was cut from (and merges into)
  local f r; f="$(state_dir)/tasks/$1.base"
  if [ -s "$f" ]; then head -n1 "$f"
  elif r=$(task_repo "$1") && [ -n "$r" ]; then state_get "feature.$r"
  else state_get feature; fi
}

# tasks_based_on [<repo>] <branch>: open task slugs whose base is <branch>,
# space-separated; with a repo (workspace mode), only that repo's tasks.
tasks_based_on() {
  local s out='' repo='' br=$1
  [ $# -lt 2 ] || { repo=$1; br=$2; }
  for s in $(open_task_slugs "$repo"); do [ "$(task_base "$s")" = "$br" ] && out+=" $s"; done
  echo "${out# }"
}

feature_change_note() { # feature_change_note <old> <new> [<repo>]
  local on
  if [ -n "${3:-}" ]; then
    on=$(tasks_based_on "$3" "$1")
    printf '%s: feature branch changed from %s to %s' "$3" "$1" "$2"
    if [ -n "$on" ]; then
      printf "; open tasks still based on %s: %s (merge each with %s's main checkout on %s)\n" "$1" "$on" "$3" "$1"
    else printf '\n'; fi
    return 0
  fi
  on=$(tasks_based_on "$1")
  printf 'feature branch changed from %s to %s' "$1" "$2"
  if [ -n "$on" ]; then
    printf '; open tasks still based on %s: %s (merge each with the main checkout on %s)\n' "$1" "$on" "$1"
  else printf '\n'; fi
}

# resolve_feature [<repo>]: sets FEATURE (the current feature branch),
# FEATURE_NOTE (the change note, when the coordinator sees a new branch for
# the first time) and FEATURE_WARN (when the main checkout is on no branch and
# the last seen one is used); FEATURE_LAST is the branch seen before a change
# (with FEATURE_NOTE). Run in the coordinator pane, it records a new
# branch as last seen, after pinning tasks without a .base to the old one.
# Returns 1 if there is no branch at all. In workspace mode it needs the repo's
# name and works on that repo (feature.<repo>=; no pinning).
FEATURE='' FEATURE_NOTE='' FEATURE_WARN='' FEATURE_LAST=''
resolve_feature() {
  local cur last s d repo='' key=feature where='the main checkout' root=''
  FEATURE='' FEATURE_NOTE='' FEATURE_WARN='' FEATURE_LAST=''
  if ws_mode; then
    repo=${1:-}
    [ -n "$repo" ] || { FEATURE_WARN="workspace mode: name the repo"; return 1; }
    root="$(ws_root)/$repo"
    [ -e "$root/.git" ] || { FEATURE_WARN="workspace mode: no repo '$repo' in $(ws_root)"; return 1; }
    key="feature.$repo" where="$repo's main checkout"
  fi
  cur=$(checkout_branch "$root"); last=$(state_get "$key")
  if [ -z "$cur" ]; then
    [ -n "$last" ] || { FEATURE_WARN="$where is on no branch (detached HEAD or rebase in progress) and no feature branch was recorded"; return 1; }
    FEATURE=$last
    FEATURE_WARN="$where is on no branch (detached HEAD or rebase in progress): using the last feature branch, $last"
    return 0
  fi
  FEATURE=$cur
  if [ -n "$last" ] && [ "$cur" != "$last" ]; then
    FEATURE_NOTE=$(feature_change_note "$last" "$cur" "$repo")
    # shellcheck disable=SC2034 # read by the scripts that source this
    FEATURE_LAST=$last
  fi
  if [ "$cur" != "$last" ] && [ "${CLAUDE_ROLE:-}" != worker ] \
     && [ -n "${REX_BLOCK:-}" ] && [ "$(state_get block)" = "$REX_BLOCK" ]; then
    d="$(state_dir)/tasks"
    if [ -n "$last" ] && [ -z "$repo" ]; then
      for s in $(open_task_slugs); do [ -s "$d/$s.base" ] || echo "$last" > "$d/$s.base"; done
    fi
    state_set "$key" "$cur"
  fi
  return 0
}

feature_branch() { # feature_branch [<repo>]: the current feature branch on stdout; warning and change note on stderr
  resolve_feature "${1:-}" || { echo "rex-coordinator: $FEATURE_WARN" >&2; return 1; }
  [ -z "$FEATURE_WARN" ] || echo "rex-coordinator: $FEATURE_WARN" >&2
  [ -z "$FEATURE_NOTE" ] || echo "rex-coordinator: $FEATURE_NOTE" >&2
  echo "$FEATURE"
}

# --- the main checkout's state (start.sh, finish-feature.sh) ----------------
checkout_busy() { # checkout_busy <root>: what is in progress (merge, rebase, ...), or nothing
  local gd f
  gd=$(git -C "$1" rev-parse --path-format=absolute --git-dir 2>/dev/null) || return 0
  for f in MERGE_HEAD CHERRY_PICK_HEAD REVERT_HEAD rebase-merge rebase-apply; do
    [ ! -e "$gd/$f" ] || { echo "a merge, rebase or cherry-pick ($f)"; return 0; }
  done
}

checkout_dirty() { # checkout_dirty <root>: true if tracked files have uncommitted changes
  [ -n "$(git -C "$1" status --porcelain --untracked-files=no 2>/dev/null)" ]
}

# --- feature pull requests (finish-feature.sh, pr-watch.sh, status.sh) -------
# features/<feature, / as -->.pr holds key=value lines: feature=, target=,
# url=, number=, forge= (github or azdo; none = github), repo= (FORGE_REPO:
# github HOST/OWNER/REPO, azdo ORG/PROJECT/REPO), created=, and merged= once
# finish-feature.sh --merge merged it.
# In workspace mode the file is features/<repo>--<feature, / as -->.pr and
# also holds ws_repo=<repo>.
feature_pr_file() { # feature_pr_file <feature> [<repo>]
  local f=${1//\//--}
  [ -z "${2:-}" ] || f="$2--$f"
  echo "$(state_dir)/features/$f.pr"
}

kv_get() { [ -f "$1" ] || return 0; sed -n "s/^$2=//p" "$1" | head -n1; } # kv_get <file> <key>: nothing if absent

kv_set() { # kv_set <file> <key> <value>: replace (or add) one key=value line
  local f=$1 tmp="$1.tmp.$$"
  { [ ! -f "$f" ] || grep -v "^$2=" "$f" || true; echo "$2=$3"; } > "$tmp" && mv -f "$tmp" "$f"
}

# --- forges: GitHub (gh) or Azure DevOps (az repos) --------------------------
# finish-feature.sh, land-task.sh, pr-watch.sh, board-watch.sh, finish-task.sh.
# A repo's forge comes from its raw remote.origin.url (an insteadOf rewrite
# doesn't count): forge_detect. forge_use sets FORGE (github|azdo) and
# FORGE_REPO (github: HOST/OWNER/REPO; azdo: ORG/PROJECT/REPO, URL-decoded,
# also split into AZ_ORG, AZ_PROJECT, AZ_REPO), and every forge_* call below
# works on those. A PR is named by its web URL; forge_pr_use <url> [<record>]
# sets the forge from a PR record's forge=/repo= (no forge=: github, as
# every record from before Azure DevOps) or, with no record, from the URL.
# Adding a forge = a case in forge_parse plus one branch per forge_* call.
# Azure DevOps: every az call names the org (--org https://dev.azure.com/<org>,
# --detect false: no az devops configure defaults), and --project/--repository
# where the command takes them (pr show/update/policy list take only --org).
FORGE='' FORGE_REPO='' AZ_ORG='' AZ_PROJECT='' AZ_REPO='' FORGE_PROBLEMS=()

gh_repo() { # gh_repo <url>: HOST/OWNER/REPO for a GitHub remote URL, or return 1
  local u=$1 host path
  case $u in
    https://*|http://*|ssh://*|git://*) u=${u#*://}; u=${u#*@}; host=${u%%/*}; path=${u#*/} ;;
    *@*:*) u=${u#*@}; host=${u%%:*}; path=${u#*:} ;;
    *) return 1 ;;
  esac
  host=${host%%:*}; path=${path%.git}; path=${path%/}
  [ "$host" = github.com ] || [ "$host" = "${GH_HOST:-github.com}" ] || return 1 # GH_HOST: GitHub Enterprise
  [[ $path =~ ^[^/]+/[^/]+$ ]] || return 1
  echo "$host/$path"
}

url_decode() { printf '%b' "${1//%/\\x}"; } # url_decode <s>: %XX escapes decoded
url_encode() { jq -rn --arg s "$1" '$s | @uri'; } # url_encode <s>: one path segment

azdo_repo() { # azdo_repo <url>: ORG/PROJECT/REPO (decoded) for an Azure DevOps remote URL, or return 1
  local u=$1 host path org='' proj='' repo=''
  case $u in
    *://*) u=${u#*://}; host=${u%%/*}; path=${u#"$host"}; path=${path#/} ;;
    *@*:*) host=${u%%:*}; path=${u#*:} ;;
    *) return 1 ;;
  esac
  host=${host##*@}; host=${host%%:*}; path=${path%/}
  case $host in
    ssh.dev.azure.com|vs-ssh.visualstudio.com) # git@ssh.dev.azure.com:v3/ORG/PROJECT/REPO
      [[ $path =~ ^v3/([^/]+)/([^/]+)/([^/]+)$ ]] || return 1
      org=${BASH_REMATCH[1]} proj=${BASH_REMATCH[2]} repo=${BASH_REMATCH[3]} ;;
    dev.azure.com) # https://[user@]dev.azure.com/ORG/PROJECT/_git/REPO (or ORG/_git/REPO)
      if [[ $path =~ ^([^/]+)/([^/]+)/_git/([^/]+)$ ]]; then
        org=${BASH_REMATCH[1]} proj=${BASH_REMATCH[2]} repo=${BASH_REMATCH[3]}
      elif [[ $path =~ ^([^/]+)/_git/([^/]+)$ ]]; then
        org=${BASH_REMATCH[1]} proj=${BASH_REMATCH[2]} repo=${BASH_REMATCH[2]}
      else return 1; fi ;;
    *.visualstudio.com) # https://ORG.visualstudio.com[/DefaultCollection]/PROJECT/_git/REPO
      org=${host%%.*}
      path=${path#[Dd]efault[Cc]ollection/}
      if [[ $path =~ ^([^/]+)/_git/([^/]+)$ ]]; then proj=${BASH_REMATCH[1]} repo=${BASH_REMATCH[2]}
      elif [[ $path =~ ^_git/([^/]+)$ ]]; then proj=${BASH_REMATCH[1]} repo=${BASH_REMATCH[1]}
      else return 1; fi ;;
    *) return 1 ;;
  esac
  echo "$(url_decode "$org")/$(url_decode "$proj")/$(url_decode "$repo")"
}

forge_parse() { # forge_parse <url>: "github HOST/OWNER/REPO" or "azdo ORG/PROJECT/REPO", or return 1
  local r
  if r=$(azdo_repo "$1"); then echo "azdo $r"
  elif r=$(gh_repo "$1"); then echo "github $r"
  else return 1; fi
}

forge_detect() { # forge_detect <root>: forge_parse of its origin (raw remote.origin.url), or return 1
  local url; url=$(git -C "$1" config --get remote.origin.url 2>/dev/null) || return 1
  forge_parse "$url"
}

forge_use() { # forge_use <forge> <repo>: set FORGE, FORGE_REPO (and AZ_*) for the forge_* calls
  FORGE=$1 FORGE_REPO=$2 AZ_ORG='' AZ_PROJECT='' AZ_REPO=''
  if [ "$FORGE" = azdo ]; then
    AZ_ORG=${2%%/*} AZ_REPO=${2##*/} AZ_PROJECT=${2#*/}; AZ_PROJECT=${AZ_PROJECT%/*}
  fi
}

forge_pr_use() { # forge_pr_use <url> [<record file>]: forge_use for that PR
  local f='' r='' u
  if [ -n "${2:-}" ] && [ -f "$2" ]; then
    f=$(kv_get "$2" forge); r=$(kv_get "$2" repo); f=${f:-github}
  else
    u=${1%/}
    if [[ $u =~ ^(.*)/pullrequest/[0-9]+$ ]] && r=$(azdo_repo "${BASH_REMATCH[1]}"); then f=azdo
    else f=github; [[ $u =~ ^(.*)/pull/[0-9]+$ ]] && r=$(gh_repo "${BASH_REMATCH[1]}") || r=''; fi
  fi
  forge_use "$f" "$r"
}

forge_name() { case $FORGE in azdo) echo "Azure DevOps" ;; *) echo GitHub ;; esac; }
forge_cli() { case $FORGE in azdo) echo az ;; *) echo gh ;; esac; } # the CLI the forge needs
forge_has_cli() { command -v "$(forge_cli)" >/dev/null 2>&1; }
FORGE_PR_RE='https?://[^ ]+/pull(request)?/[0-9]+' # a PR web URL in a tool's output

forge_pr_id() { local u=${1%/}; echo "${u##*/}"; } # forge_pr_id <url>: the PR number/id

# az with the org (and, azr, the project and repo) of FORGE_REPO; JSON out.
azo() { az "$@" --org "https://dev.azure.com/$(url_encode "$AZ_ORG")" --detect false --only-show-errors -o json; }
azr() { azo "$@" --project "$AZ_PROJECT" --repository "$AZ_REPO"; }
ghr() { gh "$@" -R "$FORGE_REPO"; }

# forge_check <root> <name>: forge_use for that repo's origin, and
# FORGE_PROBLEMS (one reason per entry) for pushing there and opening PRs:
# an origin, on GitHub or Azure DevOps, and its CLI installed and logged in
# (Azure DevOps: the azure-devops extension too, and the repo readable).
forge_check() {
  local url f='' r='' out
  forge_use '' ''; FORGE_PROBLEMS=()
  url=$(git -C "$1" config --get remote.origin.url 2>/dev/null || true)
  if [ -z "$url" ]; then
    FORGE_PROBLEMS+=("$2 has no 'origin' remote")
  elif read -r f r < <(forge_parse "$url"); then
    forge_use "$f" "$r"
  else
    FORGE_PROBLEMS+=("origin ($url) is not a GitHub or Azure DevOps repository")
  fi
  case $FORGE in
    azdo)
      if ! command -v az >/dev/null 2>&1; then
        FORGE_PROBLEMS+=("az (the Azure CLI) is not installed: https://aka.ms/azure-cli, then az extension add --name azure-devops")
      elif ! az extension show --name azure-devops -o none >/dev/null 2>&1; then
        FORGE_PROBLEMS+=("the azure-devops extension of az is not installed (az extension add --name azure-devops)")
      elif ! az account show -o none >/dev/null 2>&1; then
        FORGE_PROBLEMS+=("az is not logged in (az login)")
      elif ! out=$(azr repos show 2>&1 >/dev/null); then
        FORGE_PROBLEMS+=("az can't read $AZ_ORG/$AZ_PROJECT/$AZ_REPO on Azure DevOps: $(grep -m1 . <<<"$out" | one_line 200)")
      fi ;;
    *)
      if ! command -v gh >/dev/null 2>&1; then
        FORGE_PROBLEMS+=("gh (the GitHub CLI) is not installed: https://cli.github.com")
      elif [ -n "$FORGE_REPO" ] && ! gh auth status --hostname "${FORGE_REPO%%/*}" >/dev/null 2>&1; then
        FORGE_PROBLEMS+=("gh is not logged in to ${FORGE_REPO%%/*} (gh auth login)")
      fi ;;
  esac
  return 0
}

forge_pr_url() { # forge_pr_url <number>: the PR's web URL
  case $FORGE in
    azdo) printf 'https://dev.azure.com/%s/%s/_git/%s/pullrequest/%s\n' \
            "$(url_encode "$AZ_ORG")" "$(url_encode "$AZ_PROJECT")" "$(url_encode "$AZ_REPO")" "$1" ;;
    *) echo "https://$FORGE_REPO/pull/$1" ;;
  esac
}

forge_pr_find() { # forge_pr_find <head> [<base>]: "<url> <number>" of its open PR, nothing if none; 1 if the CLI failed
  local out
  case $FORGE in
    azdo)
      out=$(azr repos pr list --source-branch "$1" ${2:+--target-branch "$2"} --status active) || return 1
      out=$(jq -r '.[0].pullRequestId // empty' <<<"$out" 2>/dev/null) || return 1
      [ -z "$out" ] || echo "$(forge_pr_url "$out") $out" ;;
    *)
      out=$(ghr pr list --head "$1" --state open --json url,number 2>/dev/null) || return 1
      jq -r '.[0] // empty | "\(.url) \(.number)"' <<<"$out" 2>/dev/null || return 1 ;;
  esac
}

# Azure DevOps keeps at most 4000 characters of a PR description: a longer
# body is cut at a line, with a note, and keeps its last line (the attribution).
AZDO_BODY_MAX=4000
forge_fit_body() { # forge_fit_body <file>: trim it in place to the forge's limit
  [ "$FORGE" = azdo ] || return 0
  local body last note keep
  body=$(cat "$1")
  [ ${#body} -gt $AZDO_BODY_MAX ] || return 0
  last=$(tail -n1 <<<"$body")
  note=$'\n\n'"(Trimmed to Azure DevOps' $AZDO_BODY_MAX-character limit for PR descriptions.)"$'\n\n'"$last"
  keep=${body:0:$((AZDO_BODY_MAX - ${#note} - 10))}
  keep=${keep%$'\n'*}
  printf '%s%s\n' "$keep" "$note" > "$1"
}

forge_pr_create() { # forge_pr_create <base> <head> <title> <body-file>: prints the new PR's URL
  local out id t=$3
  case $FORGE in
    azdo)
      forge_fit_body "$4"
      [[ $t != @* ]] || t=" $t" # az reads "@<path>" arguments as files
      out=$(azr repos pr create --target-branch "$1" --source-branch "$2" --title "$t" \
              --description "@$4" 2>&1) || { echo "az repos pr create failed: $out" >&2; return 1; }
      id=$(jq -r '.pullRequestId // empty' <<<"$out" 2>/dev/null) || id=
      [ -n "$id" ] || { echo "az repos pr create returned no PR id: $out" >&2; return 1; }
      forge_pr_url "$id" ;;
    *)
      out=$(ghr pr create --base "$1" --head "$2" --title "$t" --body-file "$4") \
        || { echo "gh pr create failed: $out" >&2; return 1; }
      id=$(grep -Eo "$FORGE_PR_RE" <<<"$out" | tail -n1) \
        || { echo "gh pr create printed no PR URL: $out" >&2; return 1; }
      echo "$id" ;;
  esac
}

forge_pr_state() { # forge_pr_state <url>: "OPEN|MERGED|CLOSED [<merge commit sha>]"; 1 if unreadable
  local v
  case $FORGE in
    azdo)
      v=$(azo repos pr show --id "$(forge_pr_id "$1")" 2>/dev/null) || return 1
      jq -er '(.status // "") as $s
        | if $s == "completed" then "MERGED \(.lastMergeCommit.commitId // "")"
          elif $s == "abandoned" then "CLOSED"
          elif $s == "active" then "OPEN"
          else empty end' <<<"$v" 2>/dev/null ;;
    *)
      v=$(gh pr view "$1" --json state,mergeCommit 2>/dev/null) || return 1
      jq -er 'select(.state // "" | length > 0) | "\(.state) \(.mergeCommit.oid // "")"' <<<"$v" 2>/dev/null ;;
  esac
}

forge_pr_body() { # forge_pr_body <url>: the PR's description
  case $FORGE in
    azdo) azo repos pr show --id "$(forge_pr_id "$1")" 2>/dev/null | jq -r '.description // ""' ;;
    *) gh pr view "$1" --json body -q .body 2>/dev/null ;;
  esac
}

forge_pr_head() { # forge_pr_head <url>: the PR's source branch
  case $FORGE in
    azdo) azo repos pr show --id "$(forge_pr_id "$1")" 2>/dev/null | jq -r '.sourceRefName // "" | sub("^refs/heads/"; "")' ;;
    *) gh pr view "$1" --json headRefName -q .headRefName 2>/dev/null ;;
  esac
}

forge_pr_edit_body() { # forge_pr_edit_body <url> <body-file>
  case $FORGE in
    azdo) forge_fit_body "$2"; azo repos pr update --id "$(forge_pr_id "$1")" --description "@$2" >/dev/null ;;
    *) gh pr edit "$1" --body-file "$2" >/dev/null ;;
  esac
}

forge_pr_merge() { # forge_pr_merge <url>: merge it with a merge commit (the user's say-so only)
  local i st
  case $FORGE in
    azdo)
      azo repos pr update --id "$(forge_pr_id "$1")" --status completed --squash false >/dev/null || return 1
      # Completion can be queued: wait (about a minute) until it is merged.
      for ((i = 0; i < ${FORGE_MERGE_TRIES:-12}; i++)); do
        st=$(forge_pr_state "$1" || true)
        case $st in MERGED*) return 0 ;; CLOSED*) echo "$1 was abandoned" >&2; return 1 ;; esac
        sleep "${FORGE_MERGE_WAIT:-5}"
      done
      echo "$1 is not completed yet (Azure DevOps queues completion; a policy or a conflict may hold it): look at it there" >&2
      return 1 ;;
    *) ghr pr merge "$1" --merge ;;
  esac
}

forge_pr_create_hint() { # forge_pr_create_hint <base> <head>: the create command, for a plan
  case $FORGE in
    azdo) echo "az repos pr create --target-branch $1 --source-branch $2" ;;
    *) echo "gh pr create --base $1 --head $2" ;;
  esac
}

forge_pr_close_hint() { # forge_pr_close_hint <url>: the command that closes it (printed, never run)
  case $FORGE in
    azdo) echo "az repos pr update --id $(forge_pr_id "$1") --status abandoned --org https://dev.azure.com/$(url_encode "$AZ_ORG")" ;;
    *) echo "gh pr close $1" ;;
  esac
}

# forge_pr_checks <url>: the PR's checks right now, on the first line one of
# PASS (all passed), FAIL (one failed), PENDING (some still running) or NONE
# (none reported), then notes, if any. Azure DevOps: the PR's policy
# evaluations of type Build and Status (the CI ones) decide; rejected or
# broken = FAIL; other policies (reviewers, comments, work items) only get
# a note line while they are not approved.
AZDO_CHECK_TYPES='0609b952-1397-4640-95ec-e00a01b2c241 cbdc66da-9728-4af8-aada-9a5a32e4a226' # Build, Status
forge_pr_checks() {
  local out rc=0
  case $FORGE in
    azdo)
      out=$(azo repos pr policy list --id "$(forge_pr_id "$1")" 2>&1) || { echo "az repos pr policy list failed: $out" >&2; return 1; }
      jq -r --arg types "$AZDO_CHECK_TYPES" '
        ($types | split(" ")) as $ct
        | map(select(.configuration.isEnabled != false)) as $all
        | ($all | map(select(.configuration.type.id as $t | $ct | index($t)))) as $checks
        | ($all - $checks | map(select(.status != "approved" and .status != "notApplicable"))) as $other
        | (if ($checks | length) == 0 then "NONE"
           elif any($checks[]; .status == "rejected" or .status == "broken") then "FAIL"
           elif all($checks[]; .status == "approved" or .status == "notApplicable") then "PASS"
           else "PENDING" end),
          ($checks[] | "  \(.status): \(.configuration.settings.displayName // .configuration.type.displayName // "check")\(if .configuration.isBlocking then "" else " (optional)" end)"),
          ($other[] | "  not a check, \(.status): \(.configuration.type.displayName // "policy")\(if .configuration.isBlocking then " (required)" else "" end)")
      ' <<<"$out" ;;
    *)
      out=$(gh pr checks "$1" 2>&1) || rc=$?
      if [ $rc = 0 ]; then echo PASS
      elif grep -qi 'no checks reported' <<<"$out"; then echo NONE
      elif [ $rc = 8 ]; then echo PENDING # gh: checks still pending
      else echo FAIL; fi
      printf '%s\n' "$out" | sed 's/^/  /' ;;
  esac
}

# forge_pr_watch <url> <interval>: wait for the PR's checks to finish, showing
# progress, and set FORGE_RESULT to PASS or FAIL. A PR with no checks after
# about two minutes counts as PASS, with a note. GitHub: gh pr checks --watch.
# Azure DevOps: forge_pr_checks every <interval> seconds, for up to
# PR_WATCH_TIMEOUT seconds (default 3 hours; then FAIL, with a note).
FORGE_RESULT=''
# shellcheck disable=SC2034 # FORGE_RESULT: read by pr-watch.sh
forge_pr_watch() {
  local url=$1 interval=$2 tries i out res none=0 waited=0 timeout=${PR_WATCH_TIMEOUT:-10800}
  tries=$(( 120 / interval )); [ "$tries" -ge 1 ] || tries=1
  FORGE_RESULT=FAIL
  if [ "$FORGE" != azdo ]; then
    # New PRs may have no checks registered yet: wait up to ~2 minutes for some.
    for ((i = 0; i < tries; i++)); do
      out=$(gh pr checks "$url" 2>&1) && break
      if grep -qi 'no checks reported' <<<"$out"; then none=1; sleep "$interval"; continue; fi
      none=0; break
    done
    if [ $none = 1 ] && grep -qi 'no checks reported' <<<"${out:-}"; then
      echo "Note: no checks reported for $url."
      FORGE_RESULT=PASS; return 0
    fi
    if gh pr checks "$url" --watch --interval "$interval"; then FORGE_RESULT=PASS; fi
    return 0
  fi
  local last=''
  while :; do
    if out=$(forge_pr_checks "$url"); then
      res=$(head -n1 <<<"$out")
      [ "$out" = "$last" ] || { echo "Checks: $out"; last=$out; }
      case $res in
        PASS) FORGE_RESULT=PASS; return 0 ;;
        FAIL) return 0 ;;
        NONE) if [ "$waited" -ge 120 ] || [ "$waited" -ge "$timeout" ]; then echo "Note: no checks (Build or Status policies) for $url."; FORGE_RESULT=PASS; return 0; fi ;;
      esac
    fi
    if [ "$waited" -ge "$timeout" ]; then echo "Note: checks still not done after ${timeout}s on $url: counted as failed."; return 0; fi
    sleep "$interval"; waited=$((waited + interval))
  done
}

# default_target <root>: origin/HEAD's branch; else, on Azure DevOps (az
# installed), the repo's default branch there; else main.
default_target() {
  local t f r; t=$(git -C "$1" symbolic-ref --short -q refs/remotes/origin/HEAD 2>/dev/null || true)
  t=${t#origin/}
  if [ -z "$t" ] && read -r f r < <(forge_detect "$1") && [ "$f" = azdo ] && command -v az >/dev/null 2>&1; then
    t=$( (forge_use "$f" "$r"; azr repos show 2>/dev/null | jq -r '.defaultBranch // "" | sub("^refs/heads/"; "")' 2>/dev/null) || true)
  fi
  echo "${t:-main}"
}

# shellcheck disable=SC2034 # used by the scripts that source lib.sh
ATTRIBUTION='🤖 Generated with [Claude Code](https://claude.com/claude-code)'

# --- how a task lands: a local merge, or a PR into its base -------------------
# tasks/<slug>.land holds "merge" or "pr", decided by new-task.sh: --land, else
# state's land= (start.sh --land; "auto" or none = by base), else by base:
# the repo's default branch (default_target) with a GitHub or Azure DevOps
# origin (forge_detect) -> pr, any other base -> merge. Tasks from before this have no .land: merge.
land_by_base() { # land_by_base <root> <base>: pr or merge
  if [ "$2" = "$(default_target "$1")" ] && forge_detect "$1" >/dev/null; then echo pr; else echo merge; fi
}

task_land() { # task_land <slug>: merge or pr
  local l; l=$(head -n1 "$(state_dir)/tasks/$1.land" 2>/dev/null || true)
  [ "$l" = pr ] && echo pr || echo merge
}

# tasks/<slug>.pr (land-task.sh) holds key=value lines: url=, number=, base=,
# forge= (github or azdo; none = github), repo= (FORGE_REPO), created=, state= (last seen: OPEN, MERGED,
# CLOSED), checks= (pr-watch.sh: PASS or FAIL), merge_commit= once merged,
# and ws_repo=<repo> in workspace mode.
task_pr_file() { echo "$(state_dir)/tasks/$1.pr"; } # task_pr_file <slug>

report_summary() { # report_summary <file>: its Summary: line, else its first text line, else "(no report)"
  local f=$1 s=
  if [ -f "$f" ]; then
    s=$(sed -n 's/^[[:space:]]*\**Summary:\**[[:space:]]*//p' "$f" | head -n1)
    [ -n "$s" ] || s=$(grep -v -e '^[[:space:]]*$' -e '^[[:space:]]*#' "$f" | head -n1)
  fi
  s=$(printf '%s' "$s" | tr '\r\n|' '   ' | tr -s ' ' | sed 's/ *$//' | cut -c1-160)
  echo "${s:-(no report)}"
}

check_slug() {
  [[ "${1:-}" =~ ^[a-z0-9][a-z0-9._-]*$ ]] || die "slug must be lowercase letters, digits, . _ - (got '${1:-}')"
}

# --- tsk board --------------------------------------------------------------
# doctor.sh requires tsk >= 0.14.1 at activation, but every board call stays
# best-effort: skipped when tsk is not (or no longer) installed, and a
# failure only warns (to stderr), never fails the git/Rex work. Project-scoped
# calls always pass -p "$(board_project)" (the main checkout, or the
# workspace folder in workspace mode); starts always pass --no-dispatch.
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

# The tsk board is one terminal block, labelled "tsk", in a floating layer of
# its own (minimized when opened), recorded as state's tsk_block= and
# tsk_layer=. Older versions put it in a split beside the coordinator (no
# tsk_layer=); a Rex without floating layers still gets that split.
rex_has_layers() { # rex_has_layers: this Rex has floating layers (session.new_layer)
  rex api describe session.new_layer --json >/dev/null 2>&1
}

rex_block_layer() { # rex_block_layer <session> <block>: "<layer> <kind> <blocks in it>", empty if not found
  [ -n "$1" ] && [ -n "$2" ] || return 0
  rex api call -s "$1" session.view '{}' 2>/dev/null \
    | jq -r --arg b "$2" 'first(.windows[]?.layers[]? | select(any(.blocks[]?; .block_id == $b))
        | "\(.layer_id) \(.kind) \(.blocks | length)") // empty' 2>/dev/null || true
}

# rex_open_board <session> <window> <anchor block> <cwd> <tsk path>: open the
# board and print "<block> <layer>" (layer empty for the split fallback), or
# nothing when it could not be opened. Never takes focus.
rex_open_board() {
  local r b l
  if ! rex_has_layers; then
    echo "Note: this Rex has no floating panes, so the tsk board opens in a split beside this pane." >&2
    b=$(rex split -s "$1" -b "$3" --split=right --ratio 40 --focus=false \
          --label tsk -c "$4" --json -- "$5" 2>/dev/null \
        | jq -r '.block_ids[0] // empty' 2>/dev/null) || b=""
    [ -z "$b" ] || echo "$b"
    return 0
  fi
  r=$(rex api call -s "$1" session.new_layer "$(jq -nc --arg w "$2" --arg cwd "$4" --arg tsk "$5" \
        '{window_id: $w, bounds: [0.1, 0.1, 0.8, 0.8], focus: false,
          layout: {block: {flavor: "com.superlogical.terminal.shell", label: "tsk",
                           options: {command: [$tsk], cwd: $cwd}}}}')" 2>/dev/null) || r=""
  b=$(jq -r '.block_ids[0] // empty' <<<"$r" 2>/dev/null) || b=""
  l=$(jq -r '.layer_id // empty' <<<"$r" 2>/dev/null) || l=""
  [ -n "$b" ] && [ -n "$l" ] || return 0
  rex api call -s "$1" session.set_layer_state "$(jq -nc --arg l "$l" '{layer_id: $l, state: "minimized"}')" \
    >/dev/null 2>&1 || rex_warn "could not minimize the tsk board's floating pane: it stays open"
  echo "$b $l"
}

# rex_close_board <session> <block> [layer]: close the tsk board we opened, if
# it still exists. Its floating layer goes too while that layer holds only our
# block; anything else is closed by the block ID alone.
rex_close_board() {
  local where
  [ -n "$(rex_block_window "$1" "$2")" ] || return 0
  where=$(rex_block_layer "$1" "$2")
  if [ -n "${3:-}" ] && [ "$where" = "$3 floating 1" ]; then
    rex api call -s "$1" session.close_layer "$(jq -nc --arg l "$3" '{layer_id: $l}')" >/dev/null 2>&1 \
      && return 0
  fi
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

# rex_title_window <session> <window> <title>: name a Rex tab (window label).
# The label is Rex's own state, so Claude Code's OSC title writes in the tab
# don't replace it. Best-effort: a failure only warns.
rex_title_window() {
  [ -n "$2" ] && [ "$2" != null ] || { echo "rex-coordinator: no window ID: tab not titled '$3'" >&2; return 0; }
  rex window rename -s "$1" "$2" "$3" >/dev/null 2>&1 \
    || echo "rex-coordinator: could not title tab $2 '$3'" >&2
  return 0
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

# --- dated state files ----------------------------------------------------
# Briefs, reports, research answers and messages carry a YYMMDD prefix (local
# date) so `ls` sorts them by age. A task's or research topic's date is the
# day it was created, kept in tasks/<slug>.date or tasks/research-<topic>.date
# (new-task.sh, research.sh), so all files of one task share it. Older files
# have no prefix and are never renamed: lookups go through state_file.

today_stamp() { date +%y%m%d; }

dated_match() { # dated_match <dir> <name>: the newest existing <dir>/YYMMDD-<name>, if any
  local f last=
  for f in "$1"/[0-9][0-9][0-9][0-9][0-9][0-9]-"$2"; do [ -e "$f" ] && last=$f; done
  [ -z "$last" ] || echo "$last"
}

state_file() { # state_file brief|report|research <slug|topic>: path of that file
  # Dated when the task has a date (tasks/<key>.date), unless only the old
  # undated file exists; without a date, the undated file if it exists, else
  # the newest dated one, else the undated path.
  local dir sub name key d f
  dir=$(state_dir)
  case $1 in
    brief)    sub=briefs;   name=$2.md;        key=$2 ;;
    report)   sub=reports;  name=$2-report.md; key=$2 ;;
    research) sub=research; name=$2.md;        key=research-$2 ;;
    *) die "state_file: unknown kind '$1'" ;;
  esac
  d=$(head -n1 "$dir/tasks/$key.date" 2>/dev/null) || d=
  if [[ $d =~ ^[0-9]{6}$ ]]; then
    f="$dir/$sub/$d-$name"
    [ -e "$f" ] || [ ! -e "$dir/$sub/$name" ] || f="$dir/$sub/$name"
  else
    f="$dir/$sub/$name"
    [ -e "$f" ] || f=$(dated_match "$dir/$sub" "$name")
    [ -n "$f" ] || f="$dir/$sub/$name"
  fi
  echo "$f"
}
