# QNTX Attestations

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
