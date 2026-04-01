module trail;

// TODO: branch story — query all attestations for the branch and produce a full
// narrative of what happened (edits, pushes, CI, reviews). Include in additionalContext
// on Stop so Claude has the complete picture, not just individual control checks.

import controls : Control, control, stop, Trigger, Msg, msg;
import sqlite : sqlite3, sqlite3_stmt, sqlite3_prepare_v2, sqlite3_bind_text,
                sqlite3_step, sqlite3_finalize, sqlite3_column_text,
                SQLITE_OK, SQLITE_ROW, SQLITE_TRANSIENT, ZBuf;
import matcher : contains;

static immutable trailControls = [
    control("clippy-reminder", stop(),
        msg("Rust files edited after last cargo clippy run. Run cargo clippy before pushing.")),
];

struct TrailMatch {
    const(Control)* control;
    const(char)[] reason;
}

TrailMatch checkTrailControls(const(char)[] branch, sqlite3* db) {
    foreach (ref c; trailControls) {
        if (c.name == "clippy-reminder") {
            if (clippyMatch(db, branch))
                return TrailMatch(&c, c.msg.value);
        }
    }
    return TrailMatch(null, null);
}

// --- clippy-reminder matching ---
// Queries attestation rows for the branch, tracks latest timestamps for
// .rs edits, cargo clippy runs, and clippy-reminder deliveries.
// Timestamps are ISO strings — lexicographic comparison suffices.

bool clippyMatch(sqlite3* db, const(char)[] branch) {
    import sqlite : buildSubject;
    // Build the full subject (e.g. "tmp/ground:main") to match the indexed column
    __gshared ZBuf subjectVal;
    // Need cwd to build subject — get it from the global in stop.d
    import stop : g_cwd;
    buildSubject(subjectVal, g_cwd, branch);

    enum sql = "SELECT attributes, timestamp FROM attestations WHERE json_extract(subjects, '$[0]') = ?1 ORDER BY timestamp ASC\0";

    sqlite3_stmt* stmt;
    if (sqlite3_prepare_v2(db, sql.ptr, -1, &stmt, null) != SQLITE_OK)
        return false;
    sqlite3_bind_text(stmt, 1, subjectVal.ptr(), cast(int) subjectVal.len, SQLITE_TRANSIENT);

    __gshared char[32] latestClippy = 0;
    __gshared char[32] latestRs = 0;
    __gshared char[32] latestReminder = 0;
    __gshared size_t clippyLen;
    __gshared size_t rsLen;
    __gshared size_t reminderLen;
    clippyLen = 0;
    rsLen = 0;
    reminderLen = 0;

    while (sqlite3_step(stmt) == SQLITE_ROW) {
        auto attrsPtr = sqlite3_column_text(stmt, 0);
        auto tsPtr = sqlite3_column_text(stmt, 1);
        if (attrsPtr is null || tsPtr is null) continue;

        size_t attrsLen = 0;
        while (attrsPtr[attrsLen] != 0) attrsLen++;
        auto attrs = attrsPtr[0 .. attrsLen];

        size_t tsLen = 0;
        while (tsPtr[tsLen] != 0) tsLen++;
        auto ts = tsPtr[0 .. tsLen];

        // Rows are ordered ASC, so last match wins (= latest timestamp)
        if (contains(attrs, "cargo clippy")) {
            copyTs(ts, latestClippy);
            clippyLen = tsLen < 32 ? tsLen : 32;
        }
        if (contains(attrs, `.rs"`) && (contains(attrs, `"Write"`) || contains(attrs, `"Edit"`))) {
            copyTs(ts, latestRs);
            rsLen = tsLen < 32 ? tsLen : 32;
        }
        if (contains(attrs, "clippy-reminder")) {
            copyTs(ts, latestReminder);
            reminderLen = tsLen < 32 ? tsLen : 32;
        }
    }

    sqlite3_finalize(stmt);

    if (rsLen == 0) return false;
    if (reminderLen > 0 && compareTs(latestReminder[0 .. reminderLen], latestRs[0 .. rsLen]) >= 0) return false;
    if (clippyLen == 0) return true; // .rs edits but never ran clippy
    return compareTs(latestRs[0 .. rsLen], latestClippy[0 .. clippyLen]) > 0;
}

void copyTs(const(char)[] src, ref char[32] dst) {
    foreach (i; 0 .. (src.length < 32 ? src.length : 32))
        dst[i] = src[i];
}

int compareTs(const(char)[] a, const(char)[] b) {
    auto len = a.length < b.length ? a.length : b.length;
    foreach (i; 0 .. len) {
        if (a[i] < b[i]) return -1;
        if (a[i] > b[i]) return 1;
    }
    if (a.length < b.length) return -1;
    if (a.length > b.length) return 1;
    return 0;
}
