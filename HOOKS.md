# Hooks Beyond Graunde

Graunde handles controls and attestations across all hook events (see
[README.md](README.md) for registration, [reference.md](reference.md) for
payload schemas). This document covers the **additional** hooks and
environment context that sit alongside graunde.

## stop-hook-git-check.sh

A standalone Stop hook (separate from graunde) that ensures no work is lost
when a session ends. Registered as a second Stop entry in `~/.claude/settings.json`.

It checks for:

1. **Uncommitted changes** — staged or unstaged diffs.
2. **Untracked files** — new files not yet added to git.
3. **Unpushed commits** — local commits not yet pushed to the remote branch.

If any condition is true, it exits with code 2 and prints a message asking
the agent to commit and push. This blocks the session from ending cleanly
until all work is persisted to the remote.

### Recursion guard

The script reads `stop_hook_active` from the JSON stdin payload. If already
`true`, it exits immediately to prevent infinite loops (the commit/push
the agent does in response would itself trigger another Stop event).

### Script contents

```bash
#!/bin/bash

# Read the JSON input from stdin
input=$(cat)

# Check if stop hook is already active (recursion prevention)
stop_hook_active=$(echo "$input" | jq -r '.stop_hook_active')
if [[ "$stop_hook_active" = "true" ]]; then
  exit 0
fi

# Check if we're in a git repository - bail if not
if ! git rev-parse --git-dir >/dev/null 2>&1; then
  exit 0
fi

# Check for uncommitted changes (both staged and unstaged)
if ! git diff --quiet || ! git diff --cached --quiet; then
  echo "There are uncommitted changes in the repository. Please commit and push these changes to the remote branch." >&2
  exit 2
fi

# Check for untracked files that might be important
untracked_files=$(git ls-files --others --exclude-standard)
if [[ -n "$untracked_files" ]]; then
  echo "There are untracked files in the repository. Please commit and push these changes to the remote branch." >&2
  exit 2
fi

current_branch=$(git branch --show-current)
if [[ -n "$current_branch" ]]; then
  if git rev-parse "origin/$current_branch" >/dev/null 2>&1; then
    # Branch exists on remote - compare against it
    unpushed=$(git rev-list "origin/$current_branch..HEAD" --count 2>/dev/null) || unpushed=0
    if [[ "$unpushed" -gt 0 ]]; then
      echo "There are $unpushed unpushed commit(s) on branch '$current_branch'. Please push these changes to the remote repository." >&2
      exit 2
    fi
  else
    # Branch doesn't exist on remote - compare against default branch
    unpushed=$(git rev-list "origin/HEAD..HEAD" --count 2>/dev/null) || unpushed=0
    if [[ "$unpushed" -gt 0 ]]; then
      echo "Branch '$current_branch' has $unpushed unpushed commit(s) and no remote branch. Please push these changes to the remote repository." >&2
      exit 2
    fi
  fi
fi

exit 0
```

## Claude Code Web on Phone

Claude Code Web runs in a sandboxed container. When launched from a phone
the environment is distinct from a local CLI session in several ways that
matter for control scoping.

### Key env vars (captured from a live `remote_mobile` session)

| Env Var | Value | Notes |
|---|---|---|
| `CLAUDECODE` | `1` | Present in every Claude Code session (local or remote). |
| `CLAUDE_CODE_REMOTE` | `true` | Marks a remote/web session. Not set in local CLI. |
| `CLAUDE_CODE_ENTRYPOINT` | `remote_mobile` | **The phone signal.** Distinguishes mobile web from desktop web or local CLI. |
| `IS_SANDBOX` | `yes` | Sandboxed container — no access to host filesystem or network. |
| `CLAUDE_CODE_REMOTE_ENVIRONMENT_TYPE` | `cloud_default` | Container flavor. |
| `CLAUDE_CODE_VERSION` | `2.1.42` | Claude Code version running in the container. |
| `CLAUDE_CODE_BASE_REF` | `main` | Default branch the session was opened against. |
| `CLAUDE_CODE_CONTAINER_ID` | `container_011MM...` | Unique container ID for the session. |
| `CLAUDE_CODE_SESSION_ID` | `session_01MCq...` | Session UUID — same value as `session_id` in hook payloads. |

### Why this matters for scoping

`CLAUDE_CODE_ENTRYPOINT` is the key discriminator. A control can check it
to fire only in specific contexts:

- **`remote_mobile`** — phone session via Claude Code Web. The user is
  typing on a small screen, likely issuing short prompts and expecting
  autonomous execution. Controls here might be stricter (auto-commit,
  no interactive prompts) since the user can't easily intervene.
- **`remote_desktop`** — desktop browser session via Claude Code Web.
  Same sandboxed container, but the user has a full keyboard and can
  review diffs more easily.
- **Local CLI** — `CLAUDE_CODE_REMOTE` is unset. The user has full
  control, local filesystem access, and can interrupt at any time.

### Container constraints

The sandbox environment has specific characteristics:

- **Egress proxy** — all HTTP/HTTPS traffic goes through a JWT-authenticated
  proxy (`HTTP_PROXY`, `HTTPS_PROXY`, plus per-tool variants for npm, yarn,
  Java). The JWT is scoped to the session and container, with a short expiry.
- **No persistent state** — the container is ephemeral. Anything not pushed
  to the remote is lost when the session ends. This is why
  `stop-hook-git-check.sh` exists.
- **Git credentials** — pre-configured for the repo the session was opened
  against. No SSH keys; HTTPS with token auth via the proxy.
- **Tool availability** — `gh` CLI may not be installed. Tools that depend
  on it (like creating PRs) need to be part of the environment setup or
  handled by a SessionStart hook.
