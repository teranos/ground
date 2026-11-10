module codexeffort;

import effort : codexWanted, codexLowers;
import codex_policy : CodexPolicy, codexPolicyHere;
import codexrpc : CodexRpc, jsonText, textField;
import libjsonc;
import db : sqlite3, sqlite3_stmt, sqlite3_prepare_v2, sqlite3_bind_text,
    sqlite3_bind_int64, sqlite3_step, sqlite3_finalize, sqlite3_changes,
    sqlite3_last_insert_rowid, SQLITE_OK, SQLITE_DONE, SQLITE_TRANSIENT;
import core.stdc.time : time;
import core.stdc.stdlib : getenv;
import core.stdc.string : strlen;
import core.stdc.stdio : stderr, fputs, fwrite;
import zbuf : ZBuf;

extern(C) int sqlite3_bind_double(sqlite3_stmt*, int, double);

bool codexEffortEvent(json_object* payload) {
    auto event = jsonText(jsonField(payload, "hook_event_name"));
    return (event == "PreModelRequest" || event == "PostModelRequest")
        && jsonText(jsonField(payload, "session_id")).length > 0
        && jsonText(jsonField(payload, "turn_id")).length > 0;
}

// Unknown, invalid and expired readings never ask for a settings change.
double codexRemaining(json_object* result, long now) {
    auto buckets = jsonField(result, "rateLimitsByLimitId");
    json_object* bucket;
    if (json_object_get_type(buckets) == json_type.object) bucket = jsonField(buckets, "codex");
    else {
        bucket = jsonField(result, "rateLimits");
        if (jsonText(jsonField(bucket, "limitId")) != "codex") return -1;
    }
    double remaining = -1;
    static foreach (name; ["primary", "secondary"]) {{
        auto window = jsonField(bucket, name);
        auto used = jsonField(window, "usedPercent");
        auto reset = jsonField(window, "resetsAt");
        bool numeric(json_object* v) {
            auto kind = json_object_get_type(v);
            return kind == json_type.int_ || kind == json_type.double_;
        }
        if (numeric(used) && numeric(reset)) {
            auto percent = json_object_get_double(used);
            auto resets = json_object_get_double(reset);
            if (percent >= 0 && percent <= 100 && resets > now && resets < double.infinity) {
                auto left = 100 - percent;
                if (remaining < 0 || left < remaining) remaining = left;
            }
        }
    }}
    return remaining;
}

private const(char)[] knownEffort(const(char)[] value) {
    static immutable levels = ["minimal", "low", "medium", "high", "xhigh", "max", "ultra"];
    foreach (name; levels) if (name == value) return name;
    return "";
}

struct CodexEffortResult {
    const(char)[] status = "error";
    double remaining = -1;
    const(char)[] before, wanted, verified, detail;
}

// The target must already be loaded here. Never resume it on another daemon.
CodexEffortResult codexControl(ref CodexRpc rpc, const(char)[] session, long now, ref const CodexPolicy policy) {
    CodexEffortResult r;
    scope(exit) if (r.detail.length == 0 && r.status == "error") r.detail = rpc.error;
    auto params = json_object_new_object();
    scope(exit) json_object_put(params);
    bool loaded;
    ZBuf cursor;
    // Bounded even if a bad server keeps returning fresh cursors forever.
    foreach (page; 0 .. 100) {
        auto reply = rpc.call("thread/loaded/list", params);
        if (reply is null) return r;
        scope(exit) json_object_put(reply);
        auto result = jsonField(reply, "result");
        auto data = jsonField(result, "data");
        if (json_object_get_type(data) != json_type.array) { r.detail = "Invalid loaded-thread list"; return r; }
        foreach (i; 0 .. json_object_array_length(data)) {
            auto id = json_object_array_get_idx(data, i);
            if (json_object_get_type(id) != json_type.string_) { r.detail = "Invalid loaded-thread ID"; return r; }
            if (jsonText(id) == session) loaded = true;
        }
        if (loaded) break;
        auto next = jsonField(result, "nextCursor");
        if (next is null) { r.status = "unloaded"; r.detail = "Target thread is not loaded on this daemon"; return r; }
        auto text = jsonText(next);
        if (text.length == 0 || text.length >= cursor.data.length || text == cursor.slice()) {
            r.detail = "Invalid loaded-thread cursor"; return r;
        }
        cursor.reset(); cursor.put(text);
        textField(params, "cursor", cursor.slice());
    }
    if (!loaded) { r.detail = "Loaded-thread pagination exceeded limit"; return r; }
    json_object_put(params); params = json_object_new_object();
    textField(params, "threadId", session);
    json_object_object_add(params, "includeTurns", json_object_new_boolean(0));
    auto thread = rpc.call("thread/read", params);
    if (thread is null) return r;
    r.before = knownEffort(jsonText(jsonField(jsonField(jsonField(thread, "result"), "thread"), "reasoningEffort")));
    json_object_put(thread);
    if (r.before.length == 0) { r.detail = "Unknown thread effort; leaving it unchanged"; return r; }
    auto limits = rpc.call("account/rateLimits/read");
    if (limits is null) return r;
    r.remaining = codexRemaining(jsonField(limits, "result"), now);
    json_object_put(limits);
    if (r.remaining < 0) { r.detail = "No valid unexpired Codex quota window"; return r; }
    r.wanted = codexWanted(r.remaining, policy.mediumBelow, policy.lowBelow);
    if (!codexLowers(r.before, r.wanted)) { r.status = "unchanged"; return r; }
    auto update = json_object_new_object();
    scope(exit) json_object_put(update);
    textField(update, "threadId", session);
    textField(update, "effort", r.wanted);
    auto changed = rpc.call("thread/settings/update", update);
    if (changed is null) return r;
    json_object_put(changed);
    thread = rpc.call("thread/read", params);
    if (thread is null) { r.detail = "Settings update returned; verification failed"; return r; }
    r.verified = knownEffort(jsonText(jsonField(jsonField(jsonField(thread, "result"), "thread"), "reasoningEffort")));
    json_object_put(thread);
    if (r.verified != r.wanted) { r.detail = "Updated thread effort did not match readback"; return r; }
    r.status = "lowered";
    return r;
}

private void bindText(sqlite3_stmt* stmt, int index, const(char)[] text) {
    sqlite3_bind_text(stmt, index, text.ptr, cast(int) text.length, SQLITE_TRANSIENT);
}

// The insert is one atomic throttle claim. No write transaction spans the
// network call. Missing schema fails here, before any settings are changed.
long claimCodexEffort(sqlite3* db, json_object* input, long now, int interval) {
    enum sql = "INSERT INTO codex_effort_checks(session,turn_id,event,checked_at,status) "
        ~ "SELECT ?1,?2,?3,?4,'checking' WHERE NOT EXISTS "
        ~ "(SELECT 1 FROM codex_effort_checks WHERE session=?1 AND checked_at>?4-?5)";
    sqlite3_stmt* stmt;
    if (sqlite3_prepare_v2(db, sql.ptr, -1, &stmt, null) != SQLITE_OK) return -1;
    scope(exit) sqlite3_finalize(stmt);
    bindText(stmt, 1, jsonText(jsonField(input, "session_id")));
    bindText(stmt, 2, jsonText(jsonField(input, "turn_id")));
    bindText(stmt, 3, jsonText(jsonField(input, "hook_event_name")));
    sqlite3_bind_int64(stmt, 4, now);
    sqlite3_bind_int64(stmt, 5, interval);
    if (sqlite3_step(stmt) != SQLITE_DONE) return -1;
    return sqlite3_changes(db) == 1 ? sqlite3_last_insert_rowid(db) : 0;
}

private bool record(sqlite3* db, long row, ref CodexEffortResult r) {
    enum sql = "UPDATE codex_effort_checks SET completed_at=?1,status=?2,remaining_percentage=?3,"
        ~ "before_effort=?4,policy_effort=?5,verified_effort=?6,detail=?7 WHERE id=?8";
    sqlite3_stmt* stmt;
    if (sqlite3_prepare_v2(db, sql.ptr, -1, &stmt, null) != SQLITE_OK) return false;
    scope(exit) sqlite3_finalize(stmt);
    sqlite3_bind_int64(stmt, 1, cast(long) time(null));
    bindText(stmt, 2, r.status);
    if (r.remaining >= 0) sqlite3_bind_double(stmt, 3, r.remaining);
    bindText(stmt, 4, r.before); bindText(stmt, 5, r.wanted);
    bindText(stmt, 6, r.verified); bindText(stmt, 7, r.detail);
    sqlite3_bind_int64(stmt, 8, row);
    return sqlite3_step(stmt) == SQLITE_DONE;
}

// ground_hook calls this only for model events. Claude never has turn_id.
// Returns no hook directives: all failures leave the user's work running.
void codexEffortPass(sqlite3* db, const(char)[] input, const(char)[] socketPath = "") {
    auto payload = parseJson(input);
    scope(exit) json_object_put(payload);
    if (!codexEffortEvent(payload)) return;
    auto policy = codexPolicyHere(jsonText(jsonField(payload, "cwd")), jsonText(jsonField(payload, "hook_event_name")));
    if (policy.error.length) {
        fputs("ground: ", stderr); fwrite(policy.error.ptr, 1, policy.error.length, stderr); fputs("\n", stderr);
        return;
    }
    if (!policy.present || !policy.enabled) return;
    auto now = cast(long) time(null);
    auto row = claimCodexEffort(db, payload, now, policy.interval);
    if (row == 0) return;
    if (row < 0) { fputs("ground: Codex effort evidence unavailable; apply its SQL migration\n", stderr); return; }
    ZBuf path;
    if (socketPath.length) path.put(socketPath);
    else {
        auto override_ = getenv("GROUND_CODEX_SOCKET");
        if (override_ !is null) path.put(override_[0 .. strlen(override_)]);
        else {
            auto home = getenv("CODEX_HOME");
            if (home !is null) path.put(home[0 .. strlen(home)]);
            else {
                home = getenv("HOME");
                if (home !is null) { path.put(home[0 .. strlen(home)]); path.put("/.codex"); }
            }
            if (path.len) path.put("/app-server-control/app-server-control.sock");
        }
    }
    __gshared CodexRpc rpc;
    rpc.fd = -1; rpc.sequence = 0; rpc.error = "";
    scope(exit) rpc.shutdown();
    CodexEffortResult r;
    if (rpc.connectTo(path.slice())) r = codexControl(rpc, jsonText(jsonField(payload, "session_id")), now, policy);
    else r.detail = rpc.error;
    if (!record(db, row, r)) fputs("ground: could not finish Codex effort evidence row\n", stderr);
    if (r.status == "lowered") {
        fputs("ground: Codex effort set to ", stderr);
        fwrite(r.verified.ptr, 1, r.verified.length, stderr);
        fputs(" for subsequent turns\n", stderr);
    } else if (r.status == "error") {
        fputs("ground: Codex effort: ", stderr);
        fwrite(r.detail.ptr, 1, r.detail.length, stderr); fputs("\n", stderr);
    }
}
