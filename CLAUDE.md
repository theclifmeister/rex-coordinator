# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

A Claude Code plugin (`.claude-plugin/plugin.json`) that turns one Rex terminal pane into a **coordinator**: it never does the work itself, but hands each task to a fresh worker Claude in its own Rex tab and git worktree, then merges the result into a feature branch. Everything is bash + markdown; there is no build step and no test suite. Runtime deps: `rex`, `git`, `jq`, `bash`.

## Checking changes

- Lint: `shellcheck scripts/*.sh hooks-handlers/session-start.sh` (scripts source `lib.sh`, so use `shellcheck -x` from `scripts/` to follow it).
- Validate JSON: `jq . .claude-plugin/plugin.json hooks/hooks.json`.
- Real testing means installing the plugin and running `/coordinator-start` in a Rex pane of some scratch git repo. Most scripts refuse to run outside the coordinator pane (`require_coordinator`).

## How the pieces fit

- **Activation** — `/coordinator-start` (`skills/coordinator-start/`) runs `scripts/start.sh`, which writes `block=`, `session=`, `feature=` to `<git-common-dir>/rex-coordinator/state`. On every session start / `/clear` / compaction, `hooks/hooks.json` runs `hooks-handlers/session-start.sh`, which emits `additionalContext` telling Claude to load the `rex-coordinator:coordinator` skill — but only when `$REX_BLOCK` matches the recorded block and `CLAUDE_ROLE` is not `worker`. Every other pane stays silent; keep it that way.
- **Playbook** — `skills/coordinator/SKILL.md` is the coordinator's behavior spec (what to run, how to merge, rules). Changes to the flow usually mean editing this file, and keeping it consistent with the scripts it names.
- **Task lifecycle** — `new-task.sh <slug>` (branch + worktree at `.claude/worktrees/<slug>` off the feature branch, brief rendered from `skills/coordinator/brief-template.md` via `sed` placeholder substitution) → coordinator fills `{{TODO}}`s → `launch-worker.sh` (refuses while `{{TODO` remains; `rex run ... env CLAUDE_ROLE=worker claude`, stores block ID in `tasks/<slug>.block`) → worker writes `reports/<slug>-report.md` and `rex send`s `REPORT DONE|BLOCKED <slug>` → coordinator merges `--no-ff` → `finish-task.sh` (refuses unless merged, unless `--abandon`).
- **Side channels** — `research.sh` opens a read-only worker in its own background tab, in the main checkout (`tasks/research-<topic>.block`, answer in `research/<topic>.md`, no branch). `tell.sh` sends long messages via a file in `messages/` plus one short typed line, because long `rex send` input gets truncated. `watch.sh` is a background fallback that detects a report file (or, for research, a non-empty answer file), a `REPORT DONE|BLOCKED` line in a task tab, or a dead tab. It never scans a research tab's text: the typed instruction already contains `RESEARCH DONE <topic>`.
- **Memory** — `finish-task.sh` appends one line per closed task to `history.md` (date, slug, merged/abandoned/research, sha, the report's `Summary:` line, paths); `session-start.sh` puts the last 15 lines in the coordinator's context; `scripts/recall.sh <word>...` searches the ledger, briefs, reports and research answers.
- **Shared helpers** — `scripts/lib.sh` (`set -euo pipefail`, `die`, `state_dir`, `state_get`, `repo_root`, `require_coordinator`, `check_slug`). `repo_root` is derived from the git common dir so scripts work from inside a worktree too.

## Conventions and invariants

- State lives only in `<git-common-dir>/rex-coordinator/` (never committed, shared across worktrees); `start.sh` adds `.claude/worktrees/` to `.git/info/exclude` rather than `.gitignore`.
- `CLAUDE_ROLE=worker` is the guard that stops workers from coordinating; every entry point checks it.
- The message protocol strings (`REPORT DONE`, `REPORT BLOCKED`, `RESEARCH DONE`, `ACK <slug>-<n>`, and the report's first line `Summary: <one line>`) are matched across the brief template, `research.sh`, `tell.sh`, `watch.sh`, `finish-task.sh` and the playbook — change them everywhere at once.
- Brief template placeholders (`{{SLUG}}`, `{{WORKTREE}}`, `{{FEATURE}}`, `{{COORDINATOR_BLOCK}}`, `{{REPORT}}`) are filled by `new-task.sh`; `{{TODO...}}` is left for the coordinator.
- Slugs must match `^[a-z0-9][a-z0-9._-]*$` (they become branch names and file names).
- Skills reference scripts via `${CLAUDE_PLUGIN_ROOT}`; bump `version` in `plugin.json` when releasing.
