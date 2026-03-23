#!/usr/bin/env bash
#
# run-sandbox-review.sh — Run a code review inside a Docker sandbox
#
# Usage:
#   ./run-sandbox-review.sh <PR-URL-or-owner/repo#number> [--web]
#
# Options:
#   --web   Also render the review as a styled HTML page and open in the browser
#
# Examples:
#   ./run-sandbox-review.sh https://github.com/anthropics/claude-code/pull/123
#   ./run-sandbox-review.sh anthropics/claude-code#123 --web
#
# Credentials are auto-detected — no manual env var setup required:
#   - Claude Code auth: ~/.claude/ is mounted into the sandbox, then copied
#     to the agent's home dir so Claude Code picks up settings.json.
#   - GH_TOKEN: extracted from `gh auth token` (or GH_TOKEN env var)
#
# Optional environment variables:
#   SANDBOX_TIMEOUT   — Timeout in seconds (default: 1800 = 30 minutes)

set -euo pipefail

SANDBOX_TIMEOUT="${SANDBOX_TIMEOUT:-1800}"
CLAUDE_CONFIG_DIR="${CLAUDE_CONFIG_DIR:-${HOME}/.claude}"
AGENT_HOME="/home/agent"

# --- Terminal Colors ---

BOLD='\033[1m'
DIM='\033[2m'
RESET='\033[0m'
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'

# --- Helpers ---

die() {
    printf "${RED}${BOLD}ERROR${RESET} ${RED}%s${RESET}\n" "$*" >&2
    exit 1
}

usage() {
    echo "Usage: $0 <PR-URL-or-owner/repo#number> [--web]"
    echo ""
    echo "Options:"
    echo "  --web   Also render the review as a styled HTML page and open in the browser"
    echo ""
    echo "Examples:"
    echo "  $0 https://github.com/anthropics/claude-code/pull/123"
    echo "  $0 anthropics/claude-code#123 --web"
    exit 1
}

cleanup() {
    local sandbox_name="$1"
    printf "${DIM}Cleaning up sandbox...${RESET}\n" >&2
    docker sandbox rm "$sandbox_name" 2>/dev/null || true
}

# --- Credential Resolution ---
# Checks that the required credentials exist on the host.
# Nothing is created or modified — we just read from gh's auth store
# and verify ~/.claude/settings.json is present.

resolve_credentials() {
    if [[ -z "${GH_TOKEN:-}" ]]; then
        if command -v gh >/dev/null 2>&1 && gh auth status >/dev/null 2>&1; then
            GH_TOKEN=$(gh auth token 2>/dev/null) || true
        fi
    fi
    [[ -n "${GH_TOKEN:-}" ]] || die "Could not resolve GitHub token. Either set GH_TOKEN or run 'gh auth login'."
    export GH_TOKEN

    [[ -f "${CLAUDE_CONFIG_DIR}/settings.json" ]] || die "No settings.json found at ${CLAUDE_CONFIG_DIR}/settings.json. Claude Code auth config is needed for the sandbox."
}

# --- Parse PR Input ---
# Accepts a GitHub PR URL, owner/repo#number shorthand, or bare PR number.
# Sets REPO, PR_NUMBER, and PR_URL globals for use in main().

parse_pr_input() {
    local input="$1"

    if [[ "$input" =~ ^https://github\.com/([^/]+/[^/]+)/pull/([0-9]+) ]]; then
        REPO="${BASH_REMATCH[1]}"
        PR_NUMBER="${BASH_REMATCH[2]}"
        PR_URL="$input"
    elif [[ "$input" =~ ^([^/]+/[^/]+)#([0-9]+)$ ]]; then
        REPO="${BASH_REMATCH[1]}"
        PR_NUMBER="${BASH_REMATCH[2]}"
        PR_URL="https://github.com/${REPO}/pull/${PR_NUMBER}"
    elif [[ "$input" =~ ^[0-9]+$ ]]; then
        PR_NUMBER="$input"
        REPO=$(gh repo view --json nameWithOwner -q '.nameWithOwner' 2>/dev/null) \
            || die "Bare PR number requires being in a git repo with a GitHub remote"
        PR_URL="https://github.com/${REPO}/pull/${PR_NUMBER}"
    else
        die "Cannot parse PR input: $input"
    fi
}

# --- Validate Environment ---
# Checks that Docker and the sandbox feature are available.

validate_env() {
    command -v docker >/dev/null 2>&1 || die "docker is not installed"
    docker sandbox ls >/dev/null 2>&1 || die "Docker sandbox feature is not available (requires Docker Desktop 4.58+)"
}

# --- Build Meta-Prompt ---
# Generates the instructions that Claude Code will follow inside the sandbox.
# It clones the repo, runs /code-review, and writes the output to a file
# instead of posting to GitHub.

build_prompt() {
    cat <<PROMPT
First, clone the repository and enter it:
  gh repo clone ${REPO} /tmp/review-repo -- --depth=50
  cd /tmp/review-repo

Then run /code-review:code-review on pull request ${PR_URL}

CRITICAL OVERRIDES:
1. Do NOT post the review to GitHub. Instead of using \`gh pr comment\` in the final step, write the complete review text to the file ${REVIEW_OUTPUT_FILE}
2. Do NOT filter out low-confidence issues. Instead of only showing issues scoring 80+, include ALL issues found and present them in a table with their confidence score, so the user can decide which ones matter.

If the PR is not eligible for review (closed, draft, automated, already reviewed), write the reason to ${REVIEW_OUTPUT_FILE} instead.
PROMPT
}

# --- HTML Rendering ---
# When --web is passed, generates a styled HTML page from the review
# using templates/review.html and opens it in the default browser.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HTML_TEMPLATE="${SCRIPT_DIR}/../templates/review.html"

render_html() {
    local review_file="$1"
    local repo="$2"
    local pr_number="$3"
    local pr_url="$4"

    [[ -f "$HTML_TEMPLATE" ]] || die "HTML template not found: ${HTML_TEMPLATE}"

    local safe_repo
    safe_repo=$(echo "$repo" | tr '/' '-' | tr '[:upper:]' '[:lower:]')
    local html_file="/tmp/sandbox-review-${safe_repo}-${pr_number}.html"

    # HTML-escape the raw markdown (rendering is done client-side by marked.js)
    local body
    body=$(sed \
        -e 's/&/\&amp;/g' \
        -e 's/</\&lt;/g' \
        -e 's/>/\&gt;/g' \
        "$review_file")

    # Write body to a temp file so sed can read it for multi-line substitution
    local body_file
    body_file=$(mktemp)
    printf '%s' "$body" > "$body_file"

    # Substitute placeholders in template
    sed \
        -e "s|{{REPO}}|${repo}|g" \
        -e "s|{{PR_NUMBER}}|${pr_number}|g" \
        -e "s|{{PR_URL}}|${pr_url}|g" \
        -e "/{{BODY}}/{
            r ${body_file}
            d
        }" \
        "$HTML_TEMPLATE" > "$html_file"

    rm -f "$body_file"

    # Open in default browser (cross-platform)
    if command -v open >/dev/null 2>&1; then
        open "$html_file"
    elif command -v xdg-open >/dev/null 2>&1; then
        xdg-open "$html_file"
    fi
    printf "${DIM}HTML review: ${html_file}${RESET}\n" >&2
}

# --- Main ---

main() {
    local web_flag=false
    [[ $# -ge 1 ]] || usage

    validate_env
    resolve_credentials
    parse_pr_input "$1"

    if [[ "${2:-}" == "--web" ]]; then
        web_flag=true
    fi

    printf "\n${BOLD}Sandboxed Code Review${RESET}\n" >&2
    printf "${CYAN}PR${RESET}   #${PR_NUMBER} in ${BOLD}${REPO}${RESET}\n" >&2
    printf "${CYAN}URL${RESET}  ${DIM}${PR_URL}${RESET}\n\n" >&2

    # Verify PR exists and is open
    if ! gh pr view "$PR_NUMBER" --repo "$REPO" --json state -q '.state' >/dev/null 2>&1; then
        die "Cannot access PR #${PR_NUMBER} in ${REPO}. Check that the PR exists and GH_TOKEN has access."
    fi

    local pr_state
    pr_state=$(gh pr view "$PR_NUMBER" --repo "$REPO" --json state -q '.state')
    if [[ "$pr_state" != "OPEN" ]]; then
        die "PR #${PR_NUMBER} is ${pr_state}, not OPEN. Skipping review."
    fi

    # Sandbox name — keep it short to avoid Docker socket path limits (> 94 chars).
    local sandbox_hash
    sandbox_hash=$(printf '%s' "${REPO}#${PR_NUMBER}" | md5 -q 2>/dev/null || printf '%s' "${REPO}#${PR_NUMBER}" | md5sum | cut -c1-12)
    sandbox_hash="${sandbox_hash:0:12}"
    local sandbox_name="review-${sandbox_hash}"

    # Remove existing sandbox with the same name
    if docker sandbox ls --format '{{.Name}}' 2>/dev/null | grep -qx "$sandbox_name"; then
        printf "${DIM}Removing existing sandbox...${RESET}\n" >&2
        docker sandbox rm "$sandbox_name" 1>&2 || true
    fi

    printf "${BLUE}Creating sandbox${RESET} ${DIM}${sandbox_name}${RESET}\n" >&2

    # Create the sandbox with a throwaway workspace dir and ~/.claude mounted.
    local sandbox_workspace
    sandbox_workspace=$(mktemp -d)

    # Only clean up the sandbox on exit, not the workspace.
    # The workspace is in /tmp and will be cleaned by the OS.
    # Deleting it here races with run_in_background's stdout capture.
    trap "cleanup '$sandbox_name'" EXIT

    docker sandbox create \
        --name "$sandbox_name" \
        claude "$sandbox_workspace" "${CLAUDE_CONFIG_DIR}" \
        1>&2 || die "Failed to create sandbox"

    # The review output file lives in the mounted workspace.
    REVIEW_OUTPUT_FILE="${sandbox_workspace}/.review-output.txt"

    local prompt
    prompt=$(build_prompt)

    printf "${BLUE}Configuring sandbox...${RESET}\n" >&2

    # Write env vars to a file in the workspace (host-side)
    cat > "${sandbox_workspace}/.sandbox-env" <<ENVEOF
export GH_TOKEN='${GH_TOKEN}'
${ANTHROPIC_API_KEY:+export ANTHROPIC_API_KEY='${ANTHROPIC_API_KEY}'}
${ANTHROPIC_BASE_URL:+export ANTHROPIC_BASE_URL='${ANTHROPIC_BASE_URL}'}
ENVEOF

    # Write the prompt to a file in the workspace (host-side)
    printf '%s\n' "$prompt" > "${sandbox_workspace}/.review-prompt.txt"

    # Copy host's ~/.claude config into sandbox and inject env vars
    docker sandbox exec "$sandbox_name" \
        sh -c "rm -rf ${AGENT_HOME}/.claude" \
        1>&2 || die "Failed to prepare sandbox config"
    docker sandbox exec "$sandbox_name" \
        sh -c "cp -r ${CLAUDE_CONFIG_DIR} ${AGENT_HOME}/.claude" \
        1>&2 || die "Failed to copy config into sandbox"
    docker sandbox exec "$sandbox_name" \
        sh -c "cat ${sandbox_workspace}/.sandbox-env >> ${AGENT_HOME}/.bashrc" \
        1>&2 || die "Failed to inject env vars into sandbox"

    # Strip host-only settings (model, hooks, statusLine, alwaysThinking).
    # Keep only auth + plugins. The default model (Sonnet) works; opus[1m] hangs.
    cat > "${sandbox_workspace}/.strip-settings.py" <<'PYEOF'
import json
with open('settings.json') as f:
    s = json.load(f)
keep = {k: s[k] for k in ('apiKeyHelper', 'env', 'enabledPlugins') if k in s}
with open('settings.json', 'w') as f:
    json.dump(keep, f, indent=2)
PYEOF
    docker sandbox exec "$sandbox_name" \
        sh -c "cd ${AGENT_HOME}/.claude && python3 ${sandbox_workspace}/.strip-settings.py 2>/dev/null || true" \
        1>&2

    printf "${GREEN}${BOLD}Review started${RESET} ${DIM}— this typically takes 5-15 minutes. All activity is sandboxed.${RESET}\n\n" >&2

    # Run the agent in the background and poll for progress.
    docker sandbox run \
        "$sandbox_name" \
        -- -p "Read the file ${sandbox_workspace}/.review-prompt.txt and follow the instructions in it exactly." \
        >/dev/null 2>&1 &
    local sandbox_pid=$!

    # Watchdog: kill sandbox process AND container if it exceeds the timeout
    (
        sleep "$SANDBOX_TIMEOUT"
        printf "\n${RED}${BOLD}Timeout${RESET} ${RED}— review exceeded ${SANDBOX_TIMEOUT}s${RESET}\n" >&2
        kill "$sandbox_pid" 2>/dev/null
    ) &
    local watchdog_pid=$!

    # Poll for progress by reading subagent descriptions from the sandbox.
    local seen_agents=""
    local poll_interval=10

    while kill -0 "$sandbox_pid" 2>/dev/null; do
        # Check for output file (review is done)
        if docker sandbox exec "$sandbox_name" test -f "$REVIEW_OUTPUT_FILE" 2>/dev/null; then
            printf "${GREEN}✓ Review output written${RESET}\n" >&2
            sleep "$poll_interval"
            continue
        fi

        # Print new agent descriptions as they appear
        local current_agents
        current_agents=$(docker sandbox exec "$sandbox_name" sh -c '
            for f in $(find /home/agent/.claude/projects/ -name "*.meta.json" -newer /home/agent/.bashrc 2>/dev/null); do
                python3 -c "import sys,json; print(json.load(sys.stdin).get(\"description\",\"\"))" < "$f" 2>/dev/null
            done
        ' 2>/dev/null) || current_agents=""

        while IFS= read -r desc; do
            [[ -z "$desc" ]] && continue
            if [[ "$seen_agents" != *"$desc"* ]]; then
                printf "${YELLOW}▸${RESET} ${desc}\n" >&2
                seen_agents="${seen_agents}${desc}\n"
            fi
        done <<< "$current_agents"

        sleep "$poll_interval"
    done

    wait "$sandbox_pid" 2>/dev/null || true

    # Cancel the watchdog
    kill "$watchdog_pid" 2>/dev/null
    wait "$watchdog_pid" 2>/dev/null || true

    # Grace period: if the sandbox process exited but the file hasn't synced yet,
    # wait a moment and check again.
    if [[ ! -f "$REVIEW_OUTPUT_FILE" ]]; then
        sleep 3
    fi

    # Try copying the file from inside the sandbox directly in case
    # the workspace mount didn't sync the file to host in time.
    if [[ ! -f "$REVIEW_OUTPUT_FILE" ]]; then
        local recovered="${sandbox_workspace}/.review-output-recovered.txt"
        if docker sandbox exec "$sandbox_name" cat "$REVIEW_OUTPUT_FILE" > "$recovered" 2>/dev/null \
            && [[ -s "$recovered" ]]; then
            REVIEW_OUTPUT_FILE="$recovered"
            printf "${DIM}Recovered review output from sandbox.${RESET}\n" >&2
        fi
    fi

    # Output the review.
    # Disable the cleanup trap first so docker sandbox rm stderr doesn't
    # interfere with stdout capture in run_in_background.
    if [[ -f "$REVIEW_OUTPUT_FILE" && -s "$REVIEW_OUTPUT_FILE" ]]; then
        trap - EXIT
        printf "\n${GREEN}${BOLD}✓ Review complete${RESET}\n\n" >&2
        # Strip markdown syntax for cleaner terminal output
        sed \
            -e 's/^#\{1,4\} //' \
            -e 's/\*\*\([^*]*\)\*\*/\1/g' \
            -e 's/`\([^`]*\)`/\1/g' \
            -e 's/\[\([^]]*\)\]([^)]*)/\1/g' \
            -e 's/<[^>]*>//g' \
            "$REVIEW_OUTPUT_FILE"
        if [[ "$web_flag" == true ]]; then
            render_html "$REVIEW_OUTPUT_FILE" "$REPO" "$PR_NUMBER" "$PR_URL"
        fi
        # Ensure stdout is flushed before cleanup
        sync 2>/dev/null || true
        sleep 1
        cleanup "$sandbox_name"
    else
        die "No review output was produced. The sandbox may have timed out or encountered an error."
    fi
}

main "$@"
