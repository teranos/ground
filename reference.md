# Reference

What graunde sees and what it sends back, captured from a live session.

## Input (stdin)

Claude Code sends this JSON on stdin before every matched tool execution.

```json
{
  "session_id": "cf95f262-efcb-49a0-8680-48aee63bd9bb",
  "transcript_path": "/Users/.../.claude/projects/.../cf95f262-....jsonl",
  "cwd": "/Users/s.b.vanhouten/SBVH/teranos/tmp/graunde",
  "permission_mode": "default",
  "hook_event_name": "PreToolUse",
  "tool_name": "Bash",
  "tool_input": {
    "command": "go test ./...",
    "timeout": 5000,
    "description": "Trigger go test to capture graunde amendment"
  },
  "tool_use_id": "toolu_01HjS4tfcgoP3hyKfTM1Ybxt"
}
```

### Common fields

Every hook event includes these.

| Field | Description |
|-------|-------------|
| `session_id` | UUID for the current session. Stable for one `claude` invocation. |
| `transcript_path` | Absolute path to the session JSONL transcript. Every message, tool call, and result is logged here. |
| `cwd` | Working directory of the session. |
| `permission_mode` | `"default"`, `"plan"`, `"acceptEdits"`, `"dontAsk"`, or `"bypassPermissions"`. |
| `hook_event_name` | Which lifecycle event fired. |

### PreToolUse fields

| Field | Description |
|-------|-------------|
| `tool_name` | Which tool Claude is about to use: `"Bash"`, `"Edit"`, `"Write"`, `"Read"`, `"Glob"`, `"Grep"`, etc. |
| `tool_input` | The arguments Claude passed to the tool. Schema varies by tool. |
| `tool_use_id` | Unique ID for this tool call. Links to transcript lines. |

### tool_input by tool

**Bash**

| Field | Description |
|-------|-------------|
| `command` | The shell command. |
| `description` | Claude's description of what the command does. |
| `timeout` | Optional timeout in milliseconds. |
| `run_in_background` | Whether to run in background. |

**Edit**

| Field | Description |
|-------|-------------|
| `file_path` | Absolute path to the file. |
| `old_string` | Text to find. |
| `new_string` | Replacement text. |

**Write**

| Field | Description |
|-------|-------------|
| `file_path` | Absolute path to the file. |
| `content` | Content to write. |

**Read**

| Field | Description |
|-------|-------------|
| `file_path` | Absolute path to the file. |
| `offset` | Optional start line. |
| `limit` | Optional line count. |

**Glob**

| Field | Description |
|-------|-------------|
| `pattern` | Glob pattern to match files. |
| `path` | Optional directory to search. |

**Grep**

| Field | Description |
|-------|-------------|
| `pattern` | Regex pattern. |
| `path` | Optional file or directory. |

## Output (stdout)

Graunde responds via exit code and optional JSON on stdout.

### Exit codes

| Code | Effect |
|------|--------|
| `0` | Action proceeds. Stdout parsed for JSON. |
| `2` | Action blocked. Stderr fed to Claude as error. |
| other | Non-blocking error. Action proceeds. |

### Amendment (exit 0 + JSON)

When graunde matches a control and amends the command:

```json
{
  "hookSpecificOutput": {
    "hookEventName": "PreToolUse",
    "permissionDecision": "allow",
    "updatedInput": {
      "command": "go test -tags \"rustsqlite,qntxwasm\" -short ./..."
    },
    "additionalContext": "Build tags and -short are required for go test in QNTX"
  }
}
```

### No match (exit 0, no output)

Graunde exits silently. The command proceeds unchanged.

### Response fields

| Field | Description |
|-------|-------------|
| `permissionDecision` | `"allow"` — proceed, no prompt. `"deny"` — cancel the tool call. `"ask"` — show permission prompt. |
| `permissionDecisionReason` | For allow/ask: shown to user. For deny: shown to Claude as feedback. |
| `updatedInput` | Replaces the tool's input before execution. For Bash, set `command` to the amended command. |
| `additionalContext` | Injected into Claude's context as a system reminder. |

## Transcript

The `transcript_path` points to a JSONL file logging every event. The `tool_use_id` links the hook payload to transcript lines for the same tool call. Three lines per call, always near the end of the file:

**1. Intent** — Claude decides to call the tool

```json
{
  "type": "assistant",
  "message": {
    "content": [{
      "type": "tool_use",
      "id": "toolu_01DnuQjDipnSwjXzEBUj2rVs",
      "name": "Bash",
      "input": { "command": "echo \"capture test\"" }
    }]
  },
  "timestamp": "2026-03-02T11:17:41.712Z"
}
```

**2. Interception** — The hook fires

```json
{
  "type": "progress",
  "data": {
    "type": "hook_progress",
    "hookEvent": "PreToolUse",
    "hookName": "PreToolUse:Bash",
    "command": "graunde"
  },
  "toolUseID": "toolu_01DnuQjDipnSwjXzEBUj2rVs",
  "timestamp": "2026-03-02T11:17:41.715Z"
}
```

**3. Result** — The command executed

```json
{
  "type": "user",
  "message": {
    "content": [{
      "tool_use_id": "toolu_01DnuQjDipnSwjXzEBUj2rVs",
      "type": "tool_result",
      "content": "capture test",
      "is_error": false
    }]
  },
  "toolUseResult": {
    "stdout": "capture test",
    "stderr": ""
  },
  "timestamp": "2026-03-02T11:17:42.036Z"
}
```

The current tool call is always at the tail of the transcript. Read backwards to find recent context.

## Upstream docs

- [Hooks guide](https://code.claude.com/docs/en/hooks-guide)
- [Hooks reference](https://code.claude.com/docs/en/hooks)
