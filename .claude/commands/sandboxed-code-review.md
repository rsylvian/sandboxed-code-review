---
name: sandboxed-code-review
description: Run a sandboxed code review for a pull request
allowed-tools: Bash(bash *run-sandbox-review*), Bash(gh pr comment*)
---

Run a code review for the given pull request inside a Docker sandbox. The sandbox performs analysis only — it does NOT post to GitHub.

Supports an optional `--web` flag: `/sandboxed-code-review --web <PR-URL>`. When passed, the review is also rendered as a styled HTML page and opened in the default browser.

## Steps

### Step 1: Launch the review

Before launching, print this message to the user:

```
Starting sandboxed code review...

The review runs inside an isolated Docker sandbox — your local environment
is not touched. The sandbox is instructed to only analyze, not post.
No comments or changes will be posted without your explicit approval here.

This typically takes 5-15 minutes.
```

Then run the script with `run_in_background: true`. If the user passed `--web`, append it after the PR URL:

```bash
bash ~/.claude/sandboxed-code-review/scripts/run-sandbox-review.sh <PR-URL> [--web]
```

The script handles everything: PR validation, sandbox creation, credential setup, and cleanup. Pass the PR argument exactly as the user gave it (URL, `owner/repo#number`, or bare number).

IMPORTANT: You MUST set `run_in_background: true` on this Bash call. The review takes 5-15 minutes which exceeds the Bash tool timeout.

Immediately after the Bash tool call, print these two lines:

```
The review is now running in the background. I'll present the results as soon as it completes.

**Press ↓ to peek into the background task and see progress as agents are spawned inside the sandbox.**
```

### Step 2: Present the review

When the background task completes, the script's stdout contains the review. Present it with a top and bottom border only (no side borders — they break with wrapping text):

```
╭─ Sandboxed Code Review ──────────────────────────────────────
│
│  <review content here, preserving all formatting>
│  <each line prefixed with │ and two spaces>
│
╰──────────────────────────────────────────────────────────────
```

Prefix every line of the review content with `│  ` (the box-drawing vertical bar followed by two spaces). No right-side corners or borders.

### Step 3: Ask the user what to do

Ask the user (using AskUserQuestion) what they'd like to do:

- **Post to PR** — post the review as a GitHub comment
- **Edit first** — let the user modify the text before posting
- **Discard** — do nothing

If posting: `gh pr comment <number> --repo <owner/repo> --body "<review>"`
