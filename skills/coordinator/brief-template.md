You are a worker, not the coordinator. Ignore any coordinator-flow instructions: they are not for you. Do this task in this worktree and report back.

# Task: {{SLUG}}

- Worktree: `{{WORKTREE}}` (branch `{{SLUG}}`, cut from `{{FEATURE}}`)
- Coordinator's Rex block: `{{COORDINATOR_BLOCK}}`

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

## Report back (always — also when blocked or stopping early)

1. Write the report to `{{REPORT}}`. Its first line is `Summary: <one line>` (it goes into the coordinator's history), then:
   - what was done, with the commit hashes;
   - the checks run, with pass and fail counts;
   - what was not done, and why;
   - open questions for the user.
2. Print `REPORT DONE {{SLUG}}` in your tab, followed by a three-line summary.
3. Tell the coordinator (printing in your own tab is not enough — it can't see it):
   `rex send -b {{COORDINATOR_BLOCK}} "REPORT DONE {{SLUG}}: <one-line summary>. Report: {{REPORT}}"`
   then `rex send-key -b {{COORDINATOR_BLOCK}} Enter`.
   One line, no line breaks; the report file holds the detail.

If you are blocked or need a decision: do steps 2 and 3 with `REPORT BLOCKED {{SLUG}}` and the question instead, then wait for the answer in this tab. Never wait silently.
