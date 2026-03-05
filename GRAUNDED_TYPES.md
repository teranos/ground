# Graunded Types — QNTX Attestation Schema

Graunde attests type definitions on SessionStart so QNTX knows what to do with the data.

## Types

| Type | Rich string fields | Grounded variant | Verified |
|------|--------------------|------------------|----------|
| SessionStart | — | — | no |
| UserPromptSubmit | `prompt` | GraundedUserPromptSubmit | no |
| PreToolUse | — | GraundedPreToolUse | no |
| PermissionRequest | — | — | no |
| PostToolUse | — | — | no |
| PostToolUseFailure | — | — | no |
| Notification | — | — | no |
| SubagentStart | — | — | no |
| SubagentStop | — | — | no |
| Stop | `last_assistant_message` | GraundedStop | no |
| TeammateIdle | — | — | no |
| TaskCompleted | — | — | no |
| ConfigChange | — | — | no |
| WorktreeCreate | — | — | no |
| WorktreeRemove | — | — | no |
| PreCompact | — | — | no |
| Setup | — | — | no |
| SessionEnd | — | — | no |

## Schema

```sql
CREATE TABLE attestations (
    id         TEXT PRIMARY KEY,
    subjects   JSON NOT NULL,
    predicates JSON NOT NULL,
    contexts   JSON NOT NULL,
    actors     JSON NOT NULL,
    timestamp  DATETIME NOT NULL,
    source     TEXT NOT NULL DEFAULT 'cli',
    attributes JSON,
    created_at DATETIME DEFAULT CURRENT_TIMESTAMP
);
```

All array columns are JSON arrays of strings: `["a", "b"]`. `attributes` is a JSON object. `id` is any unique string.

## Query

```sql
SELECT * FROM attestations
WHERE subjects LIKE '%"some-subject"%'
ORDER BY timestamp DESC;
```

The pattern is `'%"value"%'` — quotes are part of the JSON serialization.
