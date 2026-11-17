---
name: coordinator-stop
description: Turn the Rex coordinator flow off for the current repo. User-invoked only.
disable-model-invocation: true
---

1. Run `bash "${CLAUDE_PLUGIN_ROOT}/scripts/stop.sh"`. It removes the coordinator state so later sessions start as ordinary panes. Briefs, reports, tabs and worktrees are left as they are.
2. Tell the user it's off. If the script lists tasks that are still open, list them and ask whether to merge, keep or abandon each one. Don't close anything without an answer.
3. From now on, this pane is an ordinary session: no more coordinator behaviour.
