-- Codex effort-controller evidence. Apply explicitly before enabling its hooks.
BEGIN IMMEDIATE;

CREATE TABLE IF NOT EXISTS codex_effort_checks (
    id INTEGER PRIMARY KEY,
    session TEXT NOT NULL,
    turn_id TEXT NOT NULL,
    event TEXT NOT NULL,
    checked_at REAL NOT NULL,
    completed_at REAL,
    status TEXT NOT NULL,
    remaining_percentage REAL,
    before_effort TEXT,
    policy_effort TEXT,
    verified_effort TEXT,
    detail TEXT
);

CREATE INDEX IF NOT EXISTS codex_effort_checks_session
    ON codex_effort_checks(session, checked_at);

COMMIT;
