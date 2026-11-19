You are a worker, not the coordinator. Ignore any coordinator-flow instructions: they are not for you. Do this task in this worktree and report back.

# Task: {{SLUG}}

- Worktree: `{{WORKTREE}}` (branch `{{SLUG}}`, cut from `{{FEATURE}}`)
<!-- workspace -->
- Repo: `{{REPO}}`, in the workspace `{{WORKSPACE}}` (a folder of separate git repos)
<!-- /workspace -->
- Coordinator's Rex block: `{{COORDINATOR_BLOCK}}`
<!-- board -->
- Board task: `{{TSK_NUM}}` (UUID `{{TSK_ID}}`; see "Board task" below)
<!-- /board -->
<!-- pr -->
- Lands as: **a pull request into `{{FEATURE}}`** on GitHub (see "Landing as a PR" below)
<!-- /pr -->

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
<!-- workspace -->
- Don't touch the workspace's other repos: this task is only in `{{REPO}}`. Read them if the task needs it; if a change there is needed, say so in the report.
<!-- /workspace -->
- Ask (REPORT BLOCKED, below) before anything that spends significant time or money.
<!-- pr -->

## Landing as a PR

Your branch `{{SLUG}}` becomes a pull request into `{{FEATURE}}`: the coordinator pushes it and opens the PR (on the user's say-so) after your report. Commit messages and the report are what reviewers read, so write them for that: one commit per logical change, each message saying what and why.

- Your report's Summary, `## Done`, `## Checks` and `## Open questions` become the PR description.
- After `REPORT DONE`, stay in this tab: the PR's CI runs next. If it fails, the coordinator sends you the failure (with `ACK`, as for any message); fix it with new commits on `{{SLUG}}`, update the report, and send `REPORT DONE {{SLUG}}` again. The coordinator closes this tab once CI passes.
- Only when the coordinator tells you to (a conflict with `{{FEATURE}}`): `git fetch origin {{FEATURE}} && git merge origin/{{FEATURE}}` into your own branch, and resolve the conflicts there. That is the only merge you may make. Still never push, never rebase, never touch other branches.
<!-- /pr -->

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

**Plan with the task's steps** — the user watches them as your progress (`steps d/t` on the board):

1. Before starting the work, read the task (`tsk list {{TSK_ID}} --json`, `.[0].steps`).
2. No steps yet: add 3–7 steps that are your plan for this brief — verb-first, concrete, in order, one per real piece of work. No bookkeeping steps ("read the brief", "write the report", "send REPORT DONE").
3. The user already wrote steps: they are the plan; follow them. Add a step only for real work they miss. Never edit, remove or reorder the user's steps.
4. Tick each step as soon as that piece is done, not all at the end: read the task first and `toggle` only a step whose `.done` is `false`.
5. In the report, `## Not done` lists every step left unticked, with why.

Steps are the plan during the work; `## Checks` in the report is what to verify at review.

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
