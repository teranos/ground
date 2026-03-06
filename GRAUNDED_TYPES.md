# Graunded Types — QNTX Attestation Schema

Graunde attests type definitions on SessionStart so QNTX knows what to do with the data.

- **ID**: `graunde:type:<name>:<version>` — re-attested when graunde updates.
- Attested on every SessionStart. `INSERT OR IGNORE` prevents duplicates within the same version.

## Event Types — `<Type> is type of ClaudeCode`

Attributes contain the raw Claude Code hook payload, verbatim. Type definitions specify `rich_string_fields` so QNTX knows which fields are long text. No display metadata — that's QNTX's concern.

| Type | Rich string fields | Verified |
|------|-------------------|----------|
| SessionStart | — | no |
| UserPromptSubmit | `prompt` | no |
| PreToolUse | — | no |
| PermissionRequest | — | no |
| PostToolUse | — | no |
| PostToolUseFailure | — | no |
| Notification | — | no |
| SubagentStart | — | no |
| SubagentStop | — | no |
| Stop | `last_assistant_message` | no |
| TeammateIdle | — | no |
| TaskCompleted | — | no |
| ConfigChange | — | no |
| WorktreeCreate | — | no |
| WorktreeRemove | — | no |
| PreCompact | — | no |
| Setup | — | no |
| SessionEnd | — | no |

## Grounded Types — `<Type> is type of Graunded`

When graunde acts on an event, a separate attestation is written with predicate `Graunded<Event>`. Attributes contain only graunde's own fields — the Claude Code payload stays in the corresponding event attestation, untouched.

| Type | Attribute fields | Verified |
|------|-----------------|----------|
| GraundedPreToolUse | `control`, `decision` | no |
| GraundedStop | `control` | no |
| GraundedUserPromptSubmit | `control` | no |

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
