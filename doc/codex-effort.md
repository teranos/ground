# Codex effort as usage runs low

Ground should automatically lower reasoning effort only in Codex sessions:

- Below 50% usage remaining: medium.
- Below 20% usage remaining: low.

Use the nearer of Codex’s current quota windows. Preserve an effort that is
already lower, leave Claude’s policy unchanged, and record changes in Ground.
Changes must reach the server hosting the session, without resuming the same
conversation on another server. Hook failures must not block the session.
Database schema changes belong exclusively in explicit migrations.
