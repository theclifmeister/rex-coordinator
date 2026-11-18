You are a worker, not the coordinator. Ignore any coordinator-flow instructions: they are not for you. Do this task in this worktree and report back.

# Task: {{SLUG}}

- Worktree: `{{WORKTREE}}` (branch `{{SLUG}}`, cut from `{{FEATURE}}`)
- Coordinator's Rex block: `{{COORDINATOR_BLOCK}}`
<!-- board -->
- Board task: `{{TSK_NUM}}` (UUID `{{TSK_ID}}`; see "Board task" below)
<!-- /board -->

## Goal

{{TODO: what done looks like, concretely and checkably}}

## Context

{{TODO: files and docs to read first; decisions already made; what to leave alone}}

## Scope

- In: {{TODO}}
- Out: {{TODO}}
- Don't touch: {{TODO}}

## Rules

{{TODO: the project's safety rules, verbatim from CLAUDE.md or wherever they live}}

- Work only in `{{WORKTREE}}`. Commit on branch `{{SLUG}}` only.
- Never push, never merge, never rebase other branches, never touch other worktrees.
- Ask (REPORT BLOCKED, below) before anything that spends significant time or money.

## Checks

{{TODO: the commands to run before reporting, and what "green" means}}

<!-- board -->
## Board task {{TSK_NUM}}

This task is `{{TSK_NUM}}` on the user's tsk board. The coordinator owns it: only the coordinator changes its status, notes, base or replies, and it mirrors your report there. Your limits:

- You may run only these, and always with the UUID `{{TSK_ID}}`, never the T-number alone:
  - `tsk list {{TSK_ID}} --json` — read the task (it is a JSON array: use `.[0]`).
  - `tsk steps {{TSK_ID}} add "<text>"` — add a todo for this task.
  - `tsk steps {{TSK_ID}} toggle <short_id>` — complete a todo. Toggle flips the step, so read the task first and toggle only a step whose `.done` is `false`.
- Never run `tsk status`, `edit`, `reply`, `archive`, `dispatch`, `clean` or `trash`, and never a bare `tsk add` or `tsk list`: this worktree counts as a different project on the board.
- Never retry a failed `steps add` or `toggle` blindly: read the task first, it may have gone through.
- Steps are the user's plan: add one only for real work left on this task, not for your own bookkeeping.

As written on the board when this brief was made:

{{BOARD_TASK}}

<!-- /board -->
## Report back (always — also when blocked or stopping early)

1. Write the report to `{{REPORT}}` in this layout. Its first line is `Summary: <one line>` (it goes into the coordinator's history), then these four sections, headings exactly as shown (the coordinator copies the checks and open questions onto the board task for the user's review):

   ```markdown
   Summary: <one line>

   ## Done
   <what was done, with the commit hashes>

   ## Checks
   - PASS <check and its result>
   - FAIL <check and what failed>
   - SKIP <check not run, and why>

   ## Not done
   <what was not done, and why; or none>

   ## Open questions
   - <a question for the user; or the single word none>
   ```

   Under `## Checks`, one line per check, each starting `- PASS`, `- FAIL` or `- SKIP` at the start of the line, short and on one line. Put any longer detail (setup, experiments) in its own `##` section after `## Done`, not inside `## Checks`.
2. Print `REPORT DONE {{SLUG}}` in your tab, followed by a three-line summary.
3. Tell the coordinator (printing in your own tab is not enough — it can't see it):
   `rex send -b {{COORDINATOR_BLOCK}} "REPORT DONE {{SLUG}}: <one-line summary>. Report: {{REPORT}}"`
   then `rex send-key -b {{COORDINATOR_BLOCK}} Enter`.
   One line, no line breaks; the report file holds the detail.

If you are blocked or need a decision: do steps 2 and 3 with `REPORT BLOCKED {{SLUG}}` and the question instead, then wait for the answer in this tab. Never wait silently.
