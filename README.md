# rex-coordinator

Run one Rex pane as a **coordinator**: it never does the work itself, but hands every task to a fresh worker Claude in its own Rex tab and git worktree, then merges the results back into a feature branch.

## Requirements

- Rex (`rex` on PATH; the coordinator and its workers run in Rex panes).
- `git` ≥ 2.31 (worktrees, and `rev-parse --path-format`).
- `jq`.
- `bash` (3.2, as shipped with macOS, is enough).
- Optional: [tsk](https://gettsk.sh) for the board integration; run `tsk setup` to install its Claude Code skill. Without it, everything board-related is skipped.

Check with `scripts/doctor.sh` (in the plugin directory). `/coordinator-start` runs it and refuses to activate while a required tool is missing, and the coordinator pane gets a warning at session start if `rex` or `jq` disappears.

## Install

In Claude Code:

```
/plugin marketplace add theclifmeister/rex-coordinator
/plugin install rex-coordinator@theclifmeister
```

(or from a shell: `claude plugin marketplace add theclifmeister/rex-coordinator`, then `claude plugin install rex-coordinator@theclifmeister`).

Auto-update is off by default for third-party marketplaces. Turn it on with `/plugin` → **Marketplaces** → `theclifmeister` → **Enable auto-update**, or in `~/.claude/settings.json`:

```json
"extraKnownMarketplaces": {
  "theclifmeister": {
    "source": { "source": "github", "repo": "theclifmeister/rex-coordinator" },
    "autoUpdate": true
  }
}
```

### Updating

Claude Code ships an update only when the `version` in `.claude-plugin/plugin.json` changes on `main`. With auto-update on, a new version lands in the background and applies after `/reload-plugins` or in the next session. By hand: `claude plugin marketplace update theclifmeister`, then `claude plugin update rex-coordinator@theclifmeister`. Releases and their notes are on the GitHub Releases page; tags are `vX.Y.Z`.

A coordinator that is already running keeps using the version it started with until `/clear` or a new session. Coordinator state lives in the repo's git dir, not in the plugin, so updating loses nothing.

### Developing this plugin

Keep the checkout symlinked as a skills-directory plugin (`ln -s <checkout> ~/.claude/skills/rex-coordinator`). While the marketplace install is enabled it wins and the symlinked copy is not loaded. To run your local checkout instead:

```
claude plugin disable rex-coordinator@theclifmeister   # the symlinked checkout loads
claude plugin enable rex-coordinator@theclifmeister    # back to the released version
```

Then `/reload-plugins` (or restart) in open panes. See `CLAUDE.md` for checks and the release process.

## Use

- `/coordinator-start [feature-branch]` in the pane that should coordinate. It records that pane's `$REX_BLOCK` for the current repo. With a branch name it first checks that branch out in the main checkout (only if the checkout is clean).
- The feature branch is the main checkout's current branch: to switch, `git checkout <branch>` there. New tasks branch off it; each task remembers its own base and merges back into that. `status.sh` notes a switch and flags tasks based on another branch.
- After that, a `SessionStart` hook re-activates the coordinator in that pane on every new session, `/clear` and compaction. Every other pane, and every worker (`CLAUDE_ROLE=worker`), sees nothing.
- `/coordinator-stop` turns it off.

## Layout

- `skills/coordinator/`: the playbook (`SKILL.md`) and the worker brief template.
- `skills/coordinator-start/`, `skills/coordinator-stop/`: user-only commands.
- `hooks/`, `hooks-handlers/session-start.sh`: the activation check.
- `.claude-plugin/`: `plugin.json` (the version) and `marketplace.json` (the `theclifmeister` catalog).
- `tools/bump-version.sh`, `.github/workflows/`: release tooling (see `CLAUDE.md`).
- `scripts/`: `doctor`, `start`, `stop`, `status`, `new-task`, `launch-worker`, `watch`, `research`, `tell`, `finish-task`, `recall`, `board`, `board-watch`.

State is per repo, in `<git-common-dir>/rex-coordinator/` (state with the coordinator pane and the last seen feature branch, briefs, reports, research answers, task-to-block map, task bases, task-to-board links). It is never committed. `history.md` there is a one-line-per-task ledger written by `finish-task` (paths relative to that state dir); the coordinator sees its tail at session start, and `recall` searches it with the briefs, reports and research answers. Worktrees go in `.claude/worktrees/`, which is added to `.git/info/exclude`. Research (`research.sh <topic> [--ref <branch|commit>] "<question>"`) reads a detached worktree in `.claude/worktrees/_research/<topic>` at the feature branch tip (the main checkout's branch) or the given ref, never the main checkout's working tree; `finish-task` removes it.

## tsk board

When [tsk](https://gettsk.sh) is installed, every coordinator task is linked to a task on the board (`new-task.sh <slug> T12` links T12; without a T-number a task is created, and `--title "<text>"` is then required). Task slugs starting with `research-` are reserved for research topics. The coordinator alone writes to it: `launch-worker` sets it started (always `--no-dispatch`) and notes the worker's tab, `finish-task` puts it up for review with the merge sha (or, on `--abandon`, notes it and sets it done), and `board.sh` blocks and unblocks it. Workers may only add and tick steps on their own task, by UUID. `watch.sh` reports a board reply to a blocked task, and `board-watch.sh` reports when the user sends a review back or closes it. Every call passes `-p <repo root>` where it takes a scope, and a tsk failure only warns: git and Rex work never depend on the board. Without tsk, all of this is skipped.
