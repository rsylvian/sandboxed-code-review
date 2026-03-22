<p align="left">
  <img src="./assets/logo.png" alt="Sandboxed Code Review" height="120">
</p>

# Sandboxed Code Review

Running [`/code-review`](https://github.com/anthropics/claude-code/tree/main/.claude/commands/code-review) locally means babysitting permission prompts or running in YOLO mode on your machine.

`/sandboxed-code-review` is a solution to this problem. It runs Anthropic's official `/code-review` command in a Docker sandbox fully autonomous **AND** fully isolated. No more permission prompts, no more risks to your local environment!

## Usage

```
/sandboxed-code-review <PR-URL>
/sandboxed-code-review owner/repo#123
```

The review runs in the background (typically 5-15 minutes). Progress is shown as agents are spawned inside the sandbox. When complete, the review is presented in your terminal:

```
╭─ Sandboxed Code Review ──────────────────────────────────────
│
│  Code review
│
│  | # | Issue | Confidence | Source |
│  |---|-------|-----------|--------|
│  | 1 | Missing null check in handleAuth() | 85 | Agent 2 |
│  | 2 | SQL injection risk in query builder | 92 | Agent 1, 3 |
│  ...
│
╰──────────────────────────────────────────────────────────────
```

You then choose to **post** the review to GitHub, **edit** it first, or **discard** it.

### `--web` option

```
/sandboxed-code-review <PR-URL> --web
```

In addition to the terminal output, the `--web` flag renders the review as a styled HTML page and opens it in your default browser.

## Prerequisites

- [Claude Code](https://docs.anthropic.com/en/docs/claude-code) with the [`/code-review`](https://github.com/anthropics/claude-code/tree/main/.claude/commands/code-review) command installed
- [Docker Desktop 4.58+](https://www.docker.com/products/docker-desktop/)
- [GitHub CLI (`gh`)](https://cli.github.com/) authenticated (`gh auth login`)
- A valid connection to **Anthropic API** already configured in Claude Code

## Install

```bash
# Navigate to Claude configuration directory
cd ~/.claude

# Clone the repository
git clone https://github.com/rsylvian/sandboxed-code-review.git

# Symlink the command so Claude Code discovers it globally
ln -s sandboxed-code-review/.claude/commands/sandboxed-code-review.md commands/sandboxed-code-review.md
```

The `/sandboxed-code-review` command is now available globally in any project.

## Credentials

Everything is auto-detected and no manual setup is required. The sandbox automatically inherits the `~/.claude/settings.json`, `GH_TOKEN`, `ANTHROPIC_API_KEY`, `ANTHROPIC_BASE_URL` env variables.

A read-only copy of your config is passed to the sandbox, your local files are never modified.

## Security

- The sandbox is **instructed not to post** to GitHub. All posting happens in your host session with your approval.
- `~/.claude/` is copied into the sandbox. The sandbox cannot modify your local config.
- The sandbox is destroyed after every run.

## License

[MIT](LICENSE)
