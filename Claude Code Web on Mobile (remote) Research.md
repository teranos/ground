# Active Hook Script

`~/.claude/stop-hook-git-check.sh` (runs on Stop event):

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

# Environment Variables

```
ANTHROPIC_BASE_URL=https://api.anthropic.com
BUN_INSTALL=/root/.bun
CCR_TEST_GITPROXY=1
CLAUDECODE=1
CLAUDE_AFTER_LAST_COMPACT=true
CLAUDE_AUTO_BACKGROUND_TASKS=true
CLAUDE_CODE_BASE_REF=main
CLAUDE_CODE_CONTAINER_ID=container_011MMpkeRG2LFAKRee4y3qRa--claude_code_remote--4fd6e5
CLAUDE_CODE_DEBUG=true
CLAUDE_CODE_DIAGNOSTICS_FILE=/tmp/claude-code-581166499.diag.log
CLAUDE_CODE_EMIT_TOOL_USE_SUMMARIES=true
CLAUDE_CODE_ENTRYPOINT=remote_mobile
CLAUDE_CODE_ENVIRONMENT_RUNNER_VERSION=staging-1bbe3a1c0
CLAUDE_CODE_OAUTH_TOKEN_FILE_DESCRIPTOR=4
CLAUDE_CODE_POST_FOR_SESSION_INGRESS_V2=true
CLAUDE_CODE_PROXY_RESOLVES_HOSTS=true
CLAUDE_CODE_REMOTE=true
CLAUDE_CODE_REMOTE_ENVIRONMENT_TYPE=cloud_default
CLAUDE_CODE_REMOTE_SEND_KEEPALIVES=true
CLAUDE_CODE_REMOTE_SESSION_ID=session_01MCqa14Q7Yg9QdPvY3siWbK
CLAUDE_CODE_SESSION_ID=session_01MCqa14Q7Yg9QdPvY3siWbK
CLAUDE_CODE_VERSION=2.1.42
CLAUDE_CODE_WEBSOCKET_AUTH_FILE_DESCRIPTOR=3
CLAUDE_ENABLE_STREAM_WATCHDOG=1
CLAUDE_SESSION_INGRESS_TOKEN_FILE=/home/claude/.claude/remote/.session_ingress_token
CODESIGN_MCP_PORT=48961
CODESIGN_MCP_TOKEN=skuH00cTMqr4bZlANrFdAwIy1YKaxrjK17XpJ3y8OWI=
COREPACK_ENABLE_AUTO_PIN=0
DEBIAN_FRONTEND=noninteractive
ELECTRON_GET_USE_PROXY=1
ENVRUNNER_SKIP_ACK=true
ENV_MANAGER_ENABLE_DIAG_LOGS=true
GIT_EDITOR=true
HOME=/root
IS_SANDBOX=yes
JAVA_HOME=/usr/lib/jvm/java-21-openjdk-amd64
MAX_THINKING_TOKENS=31999
MCP_CONNECTION_NONBLOCKING=true
MCP_TOOL_TIMEOUT=60000
NODE_EXTRA_CA_CERTS=/etc/ssl/certs/ca-certificates.crt
NODE_OPTIONS=--max-old-space-size=8192
NO_PROXY=localhost,127.0.0.1,169.254.169.254,metadata.google.internal,*.svc.cluster.local,*.local,*.googleapis.com,*.google.com
NoDefaultCurrentDirectoryInExePath=1
OTEL_EXPORTER_OTLP_METRICS_TEMPORALITY_PREFERENCE=delta
PATH=/root/.local/bin:/root/.cargo/bin:/usr/local/go/bin:/opt/node22/bin:/opt/maven/bin:/opt/gradle/bin:/opt/rbenv/bin:/root/.bun/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
PWD=/home/user/graunde
PYTHONUNBUFFERED=1
RBENV_ROOT=/opt/rbenv
REQUESTS_CA_BUNDLE=/etc/ssl/certs/ca-certificates.crt
RUSTUP_HOME=/root/.rustup
RUST_BACKTRACE=1
SHELL=/bin/bash
SHLVL=1
SKIP_PLUGIN_MARKETPLACE=true
SSL_CERT_FILE=/etc/ssl/certs/ca-certificates.crt
USE_BUILTIN_RIPGREP=false
USE_SHTTP_MCP=true
```
