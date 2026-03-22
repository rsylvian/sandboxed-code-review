# Sandboxed Code Review

## Overview
A Claude Code slash command (`/sandboxed-code-review`) that runs PR code reviews inside a Docker sandbox for fully autonomous, isolated execution. The sandbox performs analysis only — it is instructed NOT to post to GitHub. The review output is captured and returned to the invoking session where the user decides what to do with it.

## Architecture
```
User invokes /sandboxed-code-review <PR>
  → Command validates PR, invokes scripts/run-sandbox-review.sh
    → Docker sandbox runs Claude Code non-interactively (-p)
      → Claude invokes the real /code-review command
      → Override: write review to a file instead of posting to GitHub
    → Script captures output, returns to command
  → Command presents review to user
  → User decides: post, edit, or discard
```

**Key design decision:** We do NOT duplicate the /code-review prompt. The sandbox invokes the
real /code-review command directly, with a single override: "write to file, don't post."
This means upstream updates to /code-review are picked up automatically.

## Project Structure
- `.claude/commands/sandboxed-code-review.md` — Claude Code slash command definition
- `scripts/run-sandbox-review.sh` — Docker sandbox orchestration script
- `templates/review.html` — HTML template for `--web` output

## Conventions
- The sandbox is instructed not to post to GitHub — all posting happens in the host session
- Never duplicate the /code-review prompt — invoke it directly with an output override
- Error handling should surface clear messages about what went wrong (missing tokens, sandbox failures, etc.)
- Credentials are auto-detected from `gh auth` and `~/.claude/settings.json` — no manual env var setup required
