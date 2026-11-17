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
- `scripts/`: `start`, `stop`, `status`, `new-task`, `launch-worker`, `watch`, `research`, `tell`, `finish-task`, `recall`.

State is per repo, in `<git-common-dir>/rex-coordinator/` (state, briefs, reports, research answers, task-to-block map). It is never committed. `history.md` there is a one-line-per-task ledger written by `finish-task`; the coordinator sees its tail at session start, and `recall` searches it with the briefs, reports and research answers. Worktrees go in `.claude/worktrees/`, which is added to `.git/info/exclude`.

Requires: `rex`, `git`, `jq`, `bash`.
