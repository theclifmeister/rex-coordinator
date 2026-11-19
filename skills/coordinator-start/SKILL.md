---
name: coordinator-start
description: Make this Rex pane the coordinator for the current repo (optionally naming the feature branch), or for a workspace folder of repos. User-invoked only.
disable-model-invocation: true
argument-hint: "[feature-branch]"
compatibility: "Claude Code in a Rex terminal pane; requires rex, git >= 2.31, jq, bash, tsk >= 0.14.1"
---

Make this pane the repo's coordinator:

1. Run `bash "${CLAUDE_PLUGIN_ROOT}/scripts/start.sh" $ARGUMENTS`. It records this pane's `$REX_BLOCK` and the session, and replaces any earlier coordinator — there is only one per repo. The feature branch is always the branch the main checkout has checked out: without an argument that is the current branch; with a branch name, the script checks that branch out in the main checkout first, and refuses if the checkout has uncommitted changes or a merge/rebase in progress, or the branch doesn't exist. Later switches need no command: a plain `git checkout` in the main checkout. It also renames this Rex tab to `coordinator` and opens the tsk board in a floating pane, minimized (focus stays here); a rerun reuses it as the user left it. Tell the user they can bring the board up with `alt+t` (tsk's Rex action) or by clicking its minimized capsule, and hide it again with Rex's Minimize Floating Window (`alt+cmd+m` on macOS). An older Rex without floating panes gets a split to the right instead. Both are best-effort: if Rex can't do them, the script warns and activation still succeeds.
   Run in a folder that is **not** a git repo but has git repos as direct children, it starts **workspace mode**: one coordinator for all those repos (no branch argument; each repo's feature branch is its own checkout's branch), and prints one `<repo>: <branch> @ <sha>` line per repo. It refuses while another coordinator whose Rex pane is still open covers the same repo (a single-repo one in a member repo, or a workspace one over this repo's folder), naming that pane; if that pane is gone it takes over with a note.
2. Confirm to the user in one line: the coordinator block, the feature branch and its HEAD (workspace mode: the workspace and the repos not on their default branch). Mention any Rex layout warning or take-over note the script printed. In workspace mode also say that the task commands are not supported there yet.
3. Load the `rex-coordinator:coordinator` skill and act as the coordinator from now on. Run its session-start steps (`status.sh`) and report anything left over from earlier.

If the script refuses (a worker, not in a Rex pane, a required tool missing, a live coordinator already covering the repo, a non-git folder without repos under it, or a branch it can't check out — it runs `scripts/doctor.sh` first), tell the user why and stop.
