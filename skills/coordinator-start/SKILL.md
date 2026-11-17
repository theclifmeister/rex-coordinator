---
name: coordinator-start
description: Make this Rex pane the coordinator for the current repo (optionally naming the feature branch). User-invoked only.
disable-model-invocation: true
argument-hint: "[feature-branch]"
---

Make this pane the repo's coordinator:

1. Run `bash "${CLAUDE_PLUGIN_ROOT}/scripts/start.sh" $ARGUMENTS`. It records this pane's `$REX_BLOCK`, the session and the feature branch (default: the branch the main checkout is on), and replaces any earlier coordinator — there is only one per repo.
2. Confirm to the user in one line: the coordinator block, the feature branch and its HEAD.
3. Load the `rex-coordinator:coordinator` skill and act as the coordinator from now on. Run its session-start steps (`status.sh`) and report anything left over from earlier.

If the script refuses (a worker, or not in a Rex pane), tell the user why and stop.
