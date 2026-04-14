module trail;

// TODO: branch story — query all attestations for the branch and produce a full
// narrative of what happened (edits, pushes, CI, reviews). Include in additionalContext
// on Stop so Claude has the complete picture, not just individual control checks.

import controls : Control, control, stop, Trigger, Msg, msg;
import db : sqlite3, sqlite3_stmt, sqlite3_prepare_v2, sqlite3_bind_text,
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
    import db : buildSubject;
    __gshared ZBuf subjectVal;
    import stop : g_cwd;
    buildSubject(subjectVal, g_cwd, branch);

    // Three targeted queries instead of full table scan.
    // Each finds the latest timestamp for its category, ordered DESC LIMIT 1.

    __gshared char[32] latestClippy = 0;
    __gshared char[32] latestRs = 0;
    __gshared char[32] latestReminder = 0;
    size_t clippyLen = 0;
    size_t rsLen = 0;
    size_t reminderLen = 0;

    // Latest .rs edit (Write or Edit)
    // Match .rs" — the trailing quote ensures it's a filename ending in .rs inside JSON
    enum rsSql = "SELECT timestamp FROM attestations WHERE json_extract(subjects, '$[0]') = ?1 AND attributes LIKE '%.rs\"%' AND (attributes LIKE '%\"Write\"%' OR attributes LIKE '%\"Edit\"%') ORDER BY timestamp DESC LIMIT 1\0";
    rsLen = queryLatestTs(db, rsSql, subjectVal, latestRs);
    if (rsLen == 0) return false; // no .rs edits — nothing to check

    // Latest clippy-reminder delivery
    enum reminderSql = "SELECT timestamp FROM attestations WHERE json_extract(subjects, '$[0]') = ?1 AND attributes LIKE '%clippy-reminder%' ORDER BY timestamp DESC LIMIT 1\0";
    reminderLen = queryLatestTs(db, reminderSql, subjectVal, latestReminder);
    if (reminderLen > 0 && compareTs(latestReminder[0 .. reminderLen], latestRs[0 .. rsLen]) >= 0) return false;

    // Latest cargo clippy run
    enum clippySql = "SELECT timestamp FROM attestations WHERE json_extract(subjects, '$[0]') = ?1 AND attributes LIKE '%cargo clippy%' ORDER BY timestamp DESC LIMIT 1\0";
    clippyLen = queryLatestTs(db, clippySql, subjectVal, latestClippy);
    if (clippyLen == 0) return true; // .rs edits but never ran clippy
    return compareTs(latestRs[0 .. rsLen], latestClippy[0 .. clippyLen]) > 0;
}

size_t queryLatestTs(sqlite3* db, const(char)* sql, ref ZBuf subjectVal, ref char[32] tsBuf) {
    sqlite3_stmt* stmt;
    if (sqlite3_prepare_v2(db, sql, -1, &stmt, null) != SQLITE_OK)
        return 0;
    sqlite3_bind_text(stmt, 1, subjectVal.ptr(), cast(int) subjectVal.len, SQLITE_TRANSIENT);
    size_t len = 0;
    if (sqlite3_step(stmt) == SQLITE_ROW) {
        auto tsPtr = sqlite3_column_text(stmt, 0);
        if (tsPtr !is null) {
            while (tsPtr[len] != 0 && len < 32) { tsBuf[len] = tsPtr[len]; len++; }
        }
    }
    sqlite3_finalize(stmt);
    return len;
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
