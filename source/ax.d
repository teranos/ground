module ax;

import controls : Control, control, stop, Ax, Trigger, Msg, ax, msg;
import sqlite : sqlite3, axQuery, ZBuf;
import matcher : indexOf, contains;

static immutable axControls = [
    control("clippy-reminder", stop(),
        ax(`{"subjects":["$BRANCH"],"actors":["graunde"]}`),
        msg("Rust files edited after last cargo clippy run. Run cargo clippy before pushing.")),
];

struct AxMatch {
    const(Control)* control;
    const(char)[] reason;
}

AxMatch checkAxControls(const(char)[] branch, sqlite3* db) {
    foreach (ref c; axControls) {
        // Substitute $BRANCH in filter
        __gshared ZBuf filterBuf;
        filterBuf.reset();
        auto tmpl = c.ax.value;
        auto brIdx = indexOf(tmpl, "$BRANCH");
        if (brIdx >= 0) {
            filterBuf.put(tmpl[0 .. cast(size_t) brIdx]);
            filterBuf.put(branch);
            filterBuf.put(tmpl[cast(size_t) brIdx + 7 .. $]);
        } else {
            filterBuf.put(tmpl);
        }

        auto result = axQuery(db, filterBuf.ptr(), cast(int) filterBuf.len);
        if (result is null || result.length == 0) continue;

        if (c.name == "clippy-reminder") {
            if (clippyMatch(result))
                return AxMatch(&c, c.msg.value);
        }
    }
    return AxMatch(null, null);
}

// --- clippy-reminder matching ---
// Scans ax_query result JSON for .rs file edits after the last cargo clippy run.
// Timestamps are epoch millis (integers): "timestamp":1772588230000

bool clippyMatch(const(char)[] json) {
    long latestClippy = -1;
    long latestRs = -1;

    size_t start = 0;
    while (start < json.length) {
        // Split entries on },{
        auto sepIdx = indexOf(json[start .. $], "},{");
        size_t end;
        if (sepIdx < 0)
            end = json.length;
        else
            end = start + cast(size_t) sepIdx + 1;

        auto entry = json[start .. end];
        auto ts = extractTimestamp(entry);

        if (ts >= 0) {
            if (contains(entry, "cargo clippy") && ts > latestClippy)
                latestClippy = ts;
            if (contains(entry, `.rs"`) && ts > latestRs)
                latestRs = ts;
        }

        if (sepIdx < 0) break;
        start = start + cast(size_t) sepIdx + 2;
    }

    if (latestRs < 0) return false;
    if (latestClippy < 0) return true; // .rs edits but never ran clippy
    return latestRs > latestClippy;
}

long extractTimestamp(const(char)[] entry) {
    enum key = `"timestamp":`;
    auto idx = indexOf(entry, key);
    if (idx < 0) return -1;
    auto s = cast(size_t) idx + key.length;

    // Skip optional quote (future-proof)
    if (s < entry.length && entry[s] == '"') s++;

    long val = 0;
    bool found = false;
    while (s < entry.length && entry[s] >= '0' && entry[s] <= '9') {
        val = val * 10 + (entry[s] - '0');
        s++;
        found = true;
    }
    return found ? val : -1;
}
