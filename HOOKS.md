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

## Environment Detection

Env vars available in Claude Code sessions, useful for scoping controls:

| Env Var | Example | Notes |
|---|---|---|
| `CLAUDECODE` | `1` | Set in any Claude Code session |
| `CLAUDE_CODE_REMOTE` | `true` | Remote/web session (not local CLI) |
| `CLAUDE_CODE_ENTRYPOINT` | `remote_mobile` | How the session was launched |
| `IS_SANDBOX` | `yes` | Sandboxed container environment |

`CLAUDE_CODE_ENTRYPOINT` is particularly useful for scoping — a control
could fire only when running in `remote_mobile` vs local CLI sessions.
