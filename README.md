# rex-coordinator

Run one Rex pane as a **coordinator**: it never does the work itself, but hands every task to a fresh worker Claude in its own Rex tab and git worktree, then merges the results back into a feature branch.

## Use

- `/coordinator-start [feature-branch]` in the pane that should coordinate. It records that pane's `$REX_BLOCK` for the current repo.
- After that, a `SessionStart` hook re-activates the coordinator in that pane on every new session, `/clear` and compaction. Every other pane, and every worker (`CLAUDE_ROLE=worker`), sees nothing.
- `/coordinator-stop` turns it off.

## Layout

- `skills/coordinator/`: the playbook (`SKILL.md`) and the worker brief template.
- `skills/coordinator-start/`, `skills/coordinator-stop/`: user-only commands.
- `hooks/`, `hooks-handlers/session-start.sh`: the activation check.
- `scripts/`: `start`, `stop`, `status`, `new-task`, `launch-worker`, `watch`, `research`, `tell`, `finish-task`, `recall`, `board`, `board-watch`.

State is per repo, in `<git-common-dir>/rex-coordinator/` (state, briefs, reports, research answers, task-to-block map, task-to-board links). It is never committed. `history.md` there is a one-line-per-task ledger written by `finish-task`; the coordinator sees its tail at session start, and `recall` searches it with the briefs, reports and research answers. Worktrees go in `.claude/worktrees/`, which is added to `.git/info/exclude`. Research (`research.sh <topic> [--ref <branch|commit>] "<question>"`) reads a detached worktree in `.claude/worktrees/_research/<topic>` at the feature branch tip or the given ref, never the main checkout's working tree; `finish-task` removes it.

## tsk board

When [tsk](https://gettsk.sh) is installed, every coordinator task is linked to a task on the board (`new-task.sh <slug> T12` links T12; without a T-number a task is created). The coordinator alone writes to it: `launch-worker` sets it started (always `--no-dispatch`) and notes the worker's tab, `finish-task` puts it up for review with the merge sha (or, on `--abandon`, notes it and sets it done), and `board.sh` blocks and unblocks it. Workers may only add and tick steps on their own task, by UUID. `watch.sh` reports a board reply to a blocked task, and `board-watch.sh` reports when the user sends a review back or closes it. Every call passes `-p <repo root>` where it takes a scope, and a tsk failure only warns: git and Rex work never depend on the board. Without tsk, all of this is skipped.

Requires: `rex`, `git`, `jq`, `bash`; optional: `tsk`.
