module sessionstart;

import core.stdc.stdio : stdout, fputs;
import matcher : contains;

// Only arch — Claude already receives Platform and OS Version from the environment.
version (X86_64) enum ARCH = "x86_64";
else version (AArch64) enum ARCH = "aarch64";
else enum ARCH = "unknown";

enum SESSION_CONTEXT = `{"hookSpecificOutput":{"hookEventName":"SessionStart","additionalContext":"arch: ` ~ ARCH ~ `"}}` ~ "\n";

// Graunded Types — QNTX Attestation Schema
//
// Attested on every SessionStart so QNTX knows what to do with the data.
// ID: graunde:type:<name>:<version> — re-attested when graunde updates.
// INSERT OR IGNORE prevents duplicates within the same version.
//
// Event types — attributes contain the raw Claude Code hook payload, verbatim.
// Type definitions specify rich_string_fields so QNTX knows which fields are long text.
//
// Grounded types — when graunde acts on an event, a separate attestation records
// only graunde's own decisions. Claude's payload stays in the event attestation.
//   GraundedPreToolUse: control, decision
//   GraundedStop:       control
//   GraundedUserPromptSubmit: control
//
// Schema: see sqlite.d attestType / attestEvent.
//
// TODO: verify every event type's payload fields for rich string eligibility.
// Only UserPromptSubmit (prompt) and Stop (last_assistant_message) confirmed so far.
void attestTypes() {
    import sqlite : openDb, attestType, sqlite3_close;
    auto db = openDb();
    if (db is null) return;

    // Event types — <Type> is type of ClaudeCode
    static foreach (name; [
        "SessionStart", "PermissionRequest", "PreToolUse",
        "PostToolUse", "PostToolUseFailure", "Notification",
        "SubagentStart", "SubagentStop", "TeammateIdle",
        "TaskCompleted", "ConfigChange", "WorktreeCreate",
        "WorktreeRemove", "PreCompact", "Setup", "SessionEnd"
    ])
        attestType(db, name, "ClaudeCode", `{}`);

    attestType(db, "UserPromptSubmit", "ClaudeCode", `{"rich_string_fields":["prompt"]}`);
    attestType(db, "Stop", "ClaudeCode", `{"rich_string_fields":["last_assistant_message"]}`);

    // Grounded types — <Type> is type of Graunded
    attestType(db, "GraundedPreToolUse", "Graunded", `{}`);
    attestType(db, "GraundedStop", "Graunded", `{}`);
    attestType(db, "GraundedUserPromptSubmit", "Graunded", `{}`);

    sqlite3_close(db);
}

// TODO: extract and attest `model` field — track which model worked on what
// TODO: extract `agent_type` field — adjust controls for agent vs interactive sessions
int handleSessionStart(const(char)[] source, const(char)[] cwd) {
    attestTypes();

    // Check for project-scoped deferred messages (from QNTX)
    const(char)[] projectNews = null;
    {
        import sqlite : openDb, sqlite3_close;
        import deferred : readProjectDeferredMessage, markProjectDelivered;
        auto db = openDb();
        if (db !is null) {
            auto projDeferred = readProjectDeferredMessage(db, cwd);
            if (projDeferred.message !is null) {
                markProjectDelivered(db, projDeferred.name, projDeferred.projectContext);
                projectNews = projDeferred.message;
            }
            sqlite3_close(db);
        }
    }

    bool isStartup = source is null || contains(source, "startup") || contains(source, "clear");

    if (isStartup || projectNews !is null) {
        import parse : writeJsonString;
        fputs(`{"hookSpecificOutput":{"hookEventName":"SessionStart","additionalContext":"`, stdout);
        if (isStartup)
            fputs("arch: " ~ ARCH, stdout);
        if (isStartup && cwd !is null && contains(cwd, "/QNTX"))
            fputs(" | am.toml in the project root has the db path and node configuration. Check it before assuming database locations.", stdout);
        if (isStartup && projectNews !is null)
            fputs(" | ", stdout);
        if (projectNews !is null)
            writeJsonString(projectNews);
        fputs(`"}}` ~ "\n", stdout);
        return 0;
    }

    // TODO: compact — compaction summary may lose session-specific context graunde injected.
    //   Re-inject reminders and session state that got lost.
    // TODO: resume — happens after time away. Merges may have landed on main, branch may be stale.
    //   Check branch staleness against main, surface recent upstream changes.
    return 0;
}
