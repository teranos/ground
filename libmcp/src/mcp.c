/* SPDX-License-Identifier: MIT */
#define _GNU_SOURCE
#include "mcp.h"

#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <poll.h>
#include <signal.h>
#include <spawn.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>
#include <json-c/json.h>

extern char **environ;
typedef struct json_object json;

struct mcp_client {
    int fd;
    pid_t pid;
    int timeout_ms, shutdown_ms;
    size_t limit, used;
    char *buffer;
    char *name, *version;
    const char *protocol;
    json *capabilities;
    int64_t next_id, abandoned_id;
    bool modern, ready, broken;
    mcp_message_fn on_message;
    void *context;
};

static mcp_status fail(mcp_error *e, mcp_status code, int sys, const char *message) {
    if (e) *e = (mcp_error){.code = code, .system_errno = sys, .message = message};
    return code;
}

const char *mcp_version(void) { return MCP_VERSION; }
const char *mcp_status_string(mcp_status s) {
    static const char *const names[] = {
        "success", "invalid argument", "out of memory", "system error", "timeout",
        "end of stream", "protocol error", "remote JSON-RPC error", "invalid state",
        "message too large", "input required", "tool error", "unsupported"
    };
    return (unsigned)s < sizeof(names) / sizeof(names[0]) ? names[s] : "unknown status";
}

void mcp_options_init(mcp_options *o) {
    if (!o) return;
    *o = (mcp_options){0};
    o->client_name = "libmcp";
    o->client_version = MCP_VERSION;
    o->timeout_ms = 30000;
    o->probe_timeout_ms = 500;
    o->shutdown_timeout_ms = 1000;
    o->max_message_bytes = 1024 * 1024;
}

void mcp_response_free(mcp_response *r) {
    if (r) { free(r->json); *r = (mcp_response){0}; }
}

static int64_t now_ms(void) {
    struct timespec ts;
    if (clock_gettime(CLOCK_MONOTONIC, &ts) != 0) return -1;
    return (int64_t)ts.tv_sec * 1000 + ts.tv_nsec / 1000000;
}

static mcp_status deadline_after(int ms, int64_t *deadline, mcp_error *e) {
    int64_t now = now_ms();
    if (now < 0) return fail(e, MCP_SYSTEM_ERROR, errno, "clock_gettime");
    *deadline = now + ms;
    return MCP_OK;
}

static mcp_status wait_io(mcp_client *c, short events, int64_t deadline, mcp_error *e) {
    for (;;) {
        int64_t now = now_ms();
        if (now < 0) return fail(e, MCP_SYSTEM_ERROR, errno, "clock_gettime");
        if (now >= deadline) return fail(e, MCP_TIMEOUT, 0, "MCP request deadline elapsed");
        int64_t left = deadline - now;
        struct pollfd p = {c->fd, events, 0};
        int rc = poll(&p, 1, left > INT_MAX ? INT_MAX : (int)left);
        if (rc < 0 && errno == EINTR) continue;
        if (rc < 0) return fail(e, MCP_SYSTEM_ERROR, errno, "poll MCP stream");
        if (rc == 0) continue;
        if (p.revents & POLLNVAL) return fail(e, MCP_SYSTEM_ERROR, EBADF, "poll invalid MCP descriptor");
        return MCP_OK; /* HUP/ERR are measured by recv/send, including buffered data. */
    }
}

static mcp_status send_bytes(mcp_client *c, const char *p, size_t n, int64_t d, mcp_error *e) {
    while (n) {
        mcp_status s = wait_io(c, POLLOUT, d, e);
        if (s != MCP_OK) return s;
#ifdef MSG_NOSIGNAL
        ssize_t sent = send(c->fd, p, n, MSG_NOSIGNAL);
#else
        ssize_t sent = send(c->fd, p, n, 0); /* SO_NOSIGPIPE set at open on macOS. */
#endif
        if (sent < 0 && (errno == EINTR || errno == EAGAIN || errno == EWOULDBLOCK)) continue;
        if (sent < 0) return fail(e, MCP_SYSTEM_ERROR, errno, "send MCP message");
        if (!sent) return fail(e, MCP_EOF, 0, "MCP stream closed while sending");
        p += sent; n -= (size_t)sent;
    }
    return MCP_OK;
}

static mcp_status send_json(mcp_client *c, json *value, int64_t d, mcp_error *e) {
    const char *wire = json_object_to_json_string_ext(value, JSON_C_TO_STRING_PLAIN);
    if (!wire) return fail(e, MCP_NO_MEMORY, 0, "serialize MCP message");
    size_t n = strlen(wire);
    if (n > c->limit) return fail(e, MCP_MESSAGE_TOO_LARGE, 0, "outgoing MCP frame exceeds limit");
    mcp_status s = send_bytes(c, wire, n, d, e);
    return s == MCP_OK ? send_bytes(c, "\n", 1, d, e) : s;
}

static json *field(json *o, const char *key) {
    json *value = NULL;
    if (json_object_is_type(o, json_type_object)) json_object_object_get_ex(o, key, &value);
    return value;
}

static bool string_is(json *o, const char *text) {
    return json_object_is_type(o, json_type_string) &&
        (size_t)json_object_get_string_len(o) == strlen(text) &&
        memcmp(json_object_get_string(o), text, strlen(text)) == 0;
}

static json *parse(const char *text, size_t n) {
    if (n > INT_MAX || memchr(text, 0, n)) return NULL;
    struct json_tokener *t = json_tokener_new_ex(64);
    if (!t) return NULL;
    json_tokener_set_flags(t, JSON_TOKENER_STRICT | JSON_TOKENER_VALIDATE_UTF8);
    json *o = json_tokener_parse_ex(t, text, (int)n);
    bool ok = json_tokener_get_error(t) == json_tokener_success && json_tokener_get_parse_end(t) == n;
    json_tokener_free(t);
    if (!ok) { json_object_put(o); return NULL; }
    return o;
}

/* Object member insertion takes ownership even on failure through this helper. */
static bool add(json *o, const char *key, json *v) {
    if (!o || !v) { json_object_put(v); return false; }
    if (json_object_object_add(o, key, v) == 0) return true;
    json_object_put(v);
    return false;
}

static json *identity(mcp_client *c) {
    json *o = json_object_new_object();
    if (!add(o, "name", json_object_new_string(c->name)) ||
        !add(o, "version", json_object_new_string(c->version))) { json_object_put(o); return NULL; }
    return o;
}

static mcp_status read_frame(mcp_client *c, int64_t d, mcp_response *r, mcp_error *e) {
    for (;;) {
        /* Buffered notifications cannot extend the absolute deadline. */
        int64_t now = now_ms();
        if (now < 0) return fail(e, MCP_SYSTEM_ERROR, errno, "clock_gettime");
        if (now >= d) return fail(e, MCP_TIMEOUT, 0, "MCP request deadline elapsed");
        char *lf = memchr(c->buffer, '\n', c->used);
        if (lf) {
            size_t n = (size_t)(lf - c->buffer), consumed = n + 1;
            if (n && c->buffer[n - 1] == '\r') n--;
            r->json = malloc(n + 1);
            if (!r->json) return fail(e, MCP_NO_MEMORY, 0, "allocate received MCP frame");
            memcpy(r->json, c->buffer, n); r->json[n] = 0; r->length = n;
            c->used -= consumed;
            memmove(c->buffer, c->buffer + consumed, c->used);
            return MCP_OK;
        }
        if (c->used > c->limit) return fail(e, MCP_MESSAGE_TOO_LARGE, 0, "incoming MCP frame exceeds limit");
        mcp_status s = wait_io(c, POLLIN, d, e);
        if (s != MCP_OK) return s;
        ssize_t n = recv(c->fd, c->buffer + c->used, c->limit + 1 - c->used, 0);
        if (n < 0 && (errno == EINTR || errno == EAGAIN || errno == EWOULDBLOCK)) continue;
        if (n < 0) return fail(e, MCP_SYSTEM_ERROR, errno, "receive MCP frame");
        if (n == 0) return fail(e, c->used ? MCP_PROTOCOL_ERROR : MCP_EOF, 0,
                               c->used ? "EOF inside MCP frame" : "MCP peer closed stdout");
        c->used += (size_t)n;
    }
}

static mcp_status answer_server(mcp_client *c, json *id, json *method, int64_t d, mcp_error *e) {
    json *reply = json_object_new_object(), *body = json_object_new_object();
    bool ping = string_is(method, "ping");
    bool ok = add(reply, "jsonrpc", json_object_new_string("2.0")) &&
              add(reply, "id", json_object_get(id));
    if (!ping) ok = ok && add(body, "code", json_object_new_int(-32601)) &&
                          add(body, "message", json_object_new_string("libmcp does not provide this client capability"));
    if (!ok) { json_object_put(body); json_object_put(reply); return fail(e, MCP_NO_MEMORY, 0, "build server request reply"); }
    if (!add(reply, ping ? "result" : "error", body)) {
        json_object_put(reply); return fail(e, MCP_NO_MEMORY, 0, "build server request reply");
    }
    mcp_status s = send_json(c, reply, d, e);
    json_object_put(reply);
    return s;
}

static mcp_status receive_response(mcp_client *c, int64_t id, int64_t d,
                                    mcp_response *out, mcp_error *e) {
    for (;;) {
        mcp_response frame = {0};
        mcp_status s = read_frame(c, d, &frame, e);
        if (s != MCP_OK) return s;
        json *o = parse(frame.json, frame.length);
        json *rpc = field(o, "jsonrpc"), *rid = field(o, "id"), *method = field(o, "method");
        json *result = field(o, "result"), *err = field(o, "error");
        bool has_id = false, has_result = false, has_error = false;
        json *unused;
        if (json_object_is_type(o, json_type_object)) {
            has_id = json_object_object_get_ex(o, "id", &unused);
            has_result = json_object_object_get_ex(o, "result", &unused);
            has_error = json_object_object_get_ex(o, "error", &unused);
        }
        if (!string_is(rpc, "2.0")) goto malformed;
        if (method) {
            if (!json_object_is_type(method, json_type_string) || has_result || has_error ||
                (field(o, "params") && !json_object_is_type(field(o, "params"), json_type_object))) goto malformed;
            if (has_id && (!rid || c->modern ||
                (!json_object_is_type(rid, json_type_int) && !json_object_is_type(rid, json_type_string)))) goto malformed;
            if (c->on_message) c->on_message(c->context, frame.json, frame.length);
            if (has_id) s = answer_server(c, rid, method, d, e);
            json_object_put(o); mcp_response_free(&frame);
            if (s != MCP_OK) return s;
            continue;
        }
        if (!has_id || !json_object_is_type(rid, json_type_int) || has_result == has_error) goto malformed;
        if (json_object_get_int64(rid) != id) {
            if (c->abandoned_id && json_object_get_int64(rid) == c->abandoned_id) {
                /* Only the timed-out discovery probe is allowed a late response. */
                c->abandoned_id = 0;
                if (c->on_message) c->on_message(c->context, frame.json, frame.length);
                json_object_put(o); mcp_response_free(&frame); continue;
            }
            goto malformed;
        }
        if (has_error) {
            json *code = field(err, "code"), *message = field(err, "message");
            if (!json_object_is_type(err, json_type_object) || !json_object_is_type(code, json_type_int) ||
                !json_object_is_type(message, json_type_string)) goto malformed;
            frame.error_code = json_object_get_int64(code);
            s = fail(e, MCP_REMOTE_ERROR, 0, "server returned JSON-RPC error; see response.json");
        } else {
            if (!json_object_is_type(result, json_type_object)) goto malformed;
            json *type = field(result, "resultType");
            if (type && !string_is(type, "complete") && !string_is(type, "input_required")) goto malformed;
            json *tool_error = field(result, "isError");
            if (tool_error && !json_object_is_type(tool_error, json_type_boolean)) goto malformed;
            if (string_is(type, "input_required")) s = fail(e, MCP_INPUT_REQUIRED, 0, "server requires input; see response.json");
            else if (tool_error && json_object_get_boolean(tool_error)) s = fail(e, MCP_TOOL_ERROR, 0, "tool returned isError; see response.json");
            else s = fail(e, MCP_OK, 0, "success");
        }
        json_object_put(o); *out = frame; return s;
malformed:
        json_object_put(o); *out = frame;
        return fail(e, MCP_PROTOCOL_ERROR, 0, "invalid JSON-RPC envelope, result, or response id; see response.json");
    }
}

static mcp_status request(mcp_client *c, const char *method, json *params, int ms,
                            mcp_response *out, mcp_error *e) {
    json *o = json_object_new_object();
    if (c->next_id == INT64_MAX) { json_object_put(o); return fail(e, MCP_INVALID_STATE, 0, "MCP request id exhausted"); }
    int64_t id = ++c->next_id;
    bool ok = add(o, "jsonrpc", json_object_new_string("2.0")) &&
              add(o, "id", json_object_new_int64(id)) && add(o, "method", json_object_new_string(method));
    if (c->modern && ok) {
        json *meta = field(params, "_meta");
        if (!meta) {
            meta = json_object_new_object();
            ok = ok && add(params, "_meta", meta);
            /* add owns meta, including on failure; do not use it then. */
        }
        if (ok) ok = add(meta, "io.modelcontextprotocol/protocolVersion", json_object_new_string(c->protocol)) &&
                     add(meta, "io.modelcontextprotocol/clientCapabilities", json_object_new_object()) &&
                     add(meta, "io.modelcontextprotocol/clientInfo", identity(c));
    }
    if (ok) ok = add(o, "params", json_object_get(params));
    if (!ok) { json_object_put(o); return fail(e, MCP_NO_MEMORY, 0, "build MCP request"); }
    int64_t d;
    mcp_status s = deadline_after(ms, &d, e);
    if (s == MCP_OK) s = send_json(c, o, d, e);
    json_object_put(o);
    if (s == MCP_OK) s = receive_response(c, id, d, out, e);
    return s;
}

static bool has_version(json *versions, const char *version) {
    if (!json_object_is_type(versions, json_type_array)) return false;
    for (size_t i = 0; i < json_object_array_length(versions); i++)
        if (string_is(json_object_array_get_idx(versions, i), version)) return true;
    return false;
}

static mcp_status negotiate(mcp_client *c, const mcp_options *opt, mcp_response *r, mcp_error *e) {
    mcp_status s = MCP_OK;
    if (opt->protocol != MCP_PROTOCOL_LEGACY) {
        c->modern = true; c->protocol = MCP_PROTOCOL_VERSION;
        json *params = json_object_new_object();
        if (!params) return fail(e, MCP_NO_MEMORY, 0, "allocate discovery params");
        s = request(c, "server/discover", params, opt->probe_timeout_ms, r, e);
        json_object_put(params);
        if (s == MCP_OK) {
            json *wire = parse(r->json, r->length), *result = field(wire, "result");
            if (!has_version(field(result, "supportedVersions"), MCP_PROTOCOL_VERSION))
                s = fail(e, MCP_UNSUPPORTED, 0, "discovery offers no supported modern version; see response.json");
            else if (!json_object_is_type(field(result, "capabilities"), json_type_object))
                s = fail(e, MCP_PROTOCOL_ERROR, 0, "discovery lacks capabilities; see response.json");
            else c->capabilities = json_object_get(field(result, "capabilities"));
            json_object_put(wire);
            return s;
        }
        if (opt->protocol == MCP_PROTOCOL_MODERN || (s != MCP_TIMEOUT && s != MCP_REMOTE_ERROR) ||
            (s == MCP_REMOTE_ERROR && (r->error_code == -32020 || r->error_code == -32021 || r->error_code == -32022))) return s;
        if (s == MCP_TIMEOUT) c->abandoned_id = c->next_id;
        /* The caller opted into dual-era discovery. This is protocol fallback,
         * never a retry of a tool operation. Preserve any probe error via callback. */
        if (r->json && c->on_message) c->on_message(c->context, r->json, r->length);
        mcp_response_free(r);
    }
    c->modern = false; c->protocol = NULL;
    json *params = json_object_new_object();
    bool ok = add(params, "protocolVersion", json_object_new_string("2025-11-25")) &&
              add(params, "capabilities", json_object_new_object()) && add(params, "clientInfo", identity(c));
    if (!ok) { json_object_put(params); return fail(e, MCP_NO_MEMORY, 0, "build initialize params"); }
    s = request(c, "initialize", params, opt->timeout_ms, r, e);
    json_object_put(params);
    if (s != MCP_OK) return s;
    json *wire = parse(r->json, r->length), *result = field(wire, "result");
    json *version = field(result, "protocolVersion");
    static const char *const supported[] = {"2025-11-25", "2025-06-18", "2025-03-26", "2024-11-05"};
    for (size_t i = 0; i < sizeof(supported) / sizeof(supported[0]); i++)
        if (string_is(version, supported[i])) c->protocol = supported[i];
    if (!c->protocol || string_is(version, MCP_PROTOCOL_VERSION)) s = fail(e, MCP_UNSUPPORTED, 0, "initialize selected unsupported version; see response.json");
    else if (!json_object_is_type(field(result, "capabilities"), json_type_object) ||
             !json_object_is_type(field(result, "serverInfo"), json_type_object))
        s = fail(e, MCP_PROTOCOL_ERROR, 0, "initialize lacks capabilities or serverInfo; see response.json");
    else c->capabilities = json_object_get(field(result, "capabilities"));
    json_object_put(wire);
    if (s != MCP_OK) return s;
    json *note = json_object_new_object();
    if (!add(note, "jsonrpc", json_object_new_string("2.0")) ||
        !add(note, "method", json_object_new_string("notifications/initialized"))) {
        json_object_put(note); return fail(e, MCP_NO_MEMORY, 0, "build initialized notification");
    }
    int64_t d;
    s = deadline_after(c->timeout_ms, &d, e);
    if (s == MCP_OK) s = send_json(c, note, d, e);
    json_object_put(note);
    return s;
}

/* FDs >= 3 make spawn correct even if the embedding app closed stdin/stdout. */
static int high_fd(int fd) {
    if (fd >= 3) {
        if (fcntl(fd, F_SETFD, FD_CLOEXEC) == 0) return fd;
    } else {
        int high = fcntl(fd, F_DUPFD_CLOEXEC, 3), saved = errno;
        close(fd); errno = saved; return high;
    }
    int saved = errno; close(fd); errno = saved; return -1;
}

mcp_status mcp_client_open(const mcp_options *o, mcp_client **out, mcp_response *r, mcp_error *e) {
    if (out) *out = NULL;
    if (!o || !out || !r || r->json || !o->command || !*o->command || !o->argv || !o->argv[0] ||
        !o->client_name || !o->client_version || o->protocol < MCP_PROTOCOL_AUTO || o->protocol > MCP_PROTOCOL_LEGACY ||
        o->timeout_ms <= 0 || o->probe_timeout_ms <= 0 || o->shutdown_timeout_ms <= 0 ||
        !o->max_message_bytes || o->max_message_bytes >= INT_MAX)
        return fail(e, MCP_INVALID_ARGUMENT, 0, "invalid MCP options or nonempty response");
    mcp_client *c = calloc(1, sizeof(*c));
    if (!c) return fail(e, MCP_NO_MEMORY, 0, "allocate MCP client");
    c->fd = -1; c->pid = -1;
    c->timeout_ms = o->timeout_ms; c->shutdown_ms = o->shutdown_timeout_ms;
    c->limit = o->max_message_bytes; c->on_message = o->on_message; c->context = o->context;
    c->name = strdup(o->client_name); c->version = strdup(o->client_version);
    c->buffer = malloc(c->limit + 1);
    mcp_status s = MCP_OK;
    if (!c->name || !c->version || !c->buffer) { s = fail(e, MCP_NO_MEMORY, 0, "allocate MCP buffers"); goto failed; }
    int pair[2];
    if (socketpair(AF_UNIX, SOCK_STREAM, 0, pair) != 0) { s = fail(e, MCP_SYSTEM_ERROR, errno, "socketpair MCP stdio"); goto failed; }
    pair[0] = high_fd(pair[0]); pair[1] = high_fd(pair[1]);
    if (pair[0] < 0 || pair[1] < 0) {
        int saved = errno;
        if (pair[0] >= 0) close(pair[0]);
        if (pair[1] >= 0) close(pair[1]);
        s = fail(e, MCP_SYSTEM_ERROR, saved, "set MCP close-on-exec descriptors"); goto failed;
    }
    c->fd = pair[0];
#ifdef SO_NOSIGPIPE
    int one = 1;
    if (setsockopt(c->fd, SOL_SOCKET, SO_NOSIGPIPE, &one, sizeof(one)) != 0) {
        s = fail(e, MCP_SYSTEM_ERROR, errno, "set SO_NOSIGPIPE"); close(pair[1]); goto failed;
    }
#endif
    if (fcntl(c->fd, F_SETFL, O_NONBLOCK) != 0) {
        s = fail(e, MCP_SYSTEM_ERROR, errno, "set MCP stream nonblocking"); close(pair[1]); goto failed;
    }
    posix_spawn_file_actions_t actions;
    int rc = posix_spawn_file_actions_init(&actions);
    if (rc) { s = fail(e, MCP_SYSTEM_ERROR, rc, "init spawn actions"); close(pair[1]); goto failed; }
    rc = posix_spawn_file_actions_adddup2(&actions, pair[1], STDIN_FILENO);
    if (!rc) rc = posix_spawn_file_actions_adddup2(&actions, pair[1], STDOUT_FILENO);
    if (!rc) rc = posix_spawn_file_actions_addclose(&actions, pair[0]);
    if (!rc) rc = posix_spawn_file_actions_addclose(&actions, pair[1]);
    if (!rc && o->cwd) rc = posix_spawn_file_actions_addchdir_np(&actions, o->cwd);
    if (!rc) rc = posix_spawnp(&c->pid, o->command, &actions, NULL, (char *const *)o->argv,
                              o->envp ? (char *const *)o->envp : environ);
    posix_spawn_file_actions_destroy(&actions);
    close(pair[1]);
    if (rc) { s = fail(e, MCP_SYSTEM_ERROR, rc, "spawn MCP server"); goto failed; }
    s = negotiate(c, o, r, e);
    if (s == MCP_OK) { c->ready = true; *out = c; return fail(e, MCP_OK, 0, "success"); }
failed:
    /* Opening failed: preserve that error and the peer's full response. */
    {
        mcp_error cleanup = {0};
        if (mcp_client_close(c, &cleanup) != MCP_OK && e) {
            e->cleanup_code = cleanup.code;
            e->cleanup_errno = cleanup.system_errno;
            e->cleanup_child_status = cleanup.child_status;
            e->cleanup_message = cleanup.message;
        }
    }
    return s;
}

const char *mcp_client_protocol_version(const mcp_client *c) { return c ? c->protocol : NULL; }

mcp_status mcp_client_request(mcp_client *c, const char *method, const char *text, mcp_response *r, mcp_error *e) {
    if (!c || !method || !*method || !r || r->json)
        return fail(e, MCP_INVALID_ARGUMENT, 0, "invalid request arguments or nonempty response");
    if (!c->ready || c->broken) return fail(e, MCP_INVALID_STATE, 0, "MCP client is not usable; close it");
    json *params = text ? parse(text, strlen(text)) : json_object_new_object();
    json *meta = NULL;
    bool has_meta = json_object_is_type(params, json_type_object) && json_object_object_get_ex(params, "_meta", &meta);
    if (!json_object_is_type(params, json_type_object) || (has_meta && !json_object_is_type(meta, json_type_object))) {
        json_object_put(params); return fail(e, MCP_INVALID_ARGUMENT, 0, "params and optional _meta must be JSON objects");
    }
    mcp_status s = request(c, method, params, c->timeout_ms, r, e);
    json_object_put(params);
    if (s != MCP_OK && s != MCP_REMOTE_ERROR && s != MCP_TOOL_ERROR && s != MCP_INPUT_REQUIRED && s != MCP_INVALID_ARGUMENT) c->broken = true;
    return s;
}

static mcp_status helper(mcp_client *c, const char *cap, const char *method, const char *key,
                          const char *value, const char *args, mcp_response *r, mcp_error *e) {
    if (!c || !r || r->json || (key && !value)) return fail(e, MCP_INVALID_ARGUMENT, 0, "invalid MCP helper arguments");
    if (!c->ready || c->broken) return fail(e, MCP_INVALID_STATE, 0, "MCP client is not usable; close it");
    if (!json_object_is_type(field(c->capabilities, cap), json_type_object))
        return fail(e, MCP_UNSUPPORTED, 0, "server did not advertise requested capability");
    json *params = json_object_new_object();
    if (!params) return fail(e, MCP_NO_MEMORY, 0, "allocate MCP helper params");
    bool ok = !key || add(params, key, json_object_new_string(value));
    if (args) {
        json *arguments = parse(args, strlen(args));
        if (!json_object_is_type(arguments, json_type_object)) {
            json_object_put(arguments); json_object_put(params);
            return fail(e, MCP_INVALID_ARGUMENT, 0, "tool/prompt arguments must be a JSON object");
        }
        ok = add(params, "arguments", arguments) && ok;
    }
    if (!ok) { json_object_put(params); return fail(e, MCP_NO_MEMORY, 0, "build MCP helper params"); }
    const char *text = json_object_to_json_string_ext(params, JSON_C_TO_STRING_PLAIN);
    mcp_status s = text ? mcp_client_request(c, method, text, r, e) : fail(e, MCP_NO_MEMORY, 0, "serialize MCP helper params");
    json_object_put(params);
    return s;
}

mcp_status mcp_tools_list(mcp_client *c, const char *v, mcp_response *r, mcp_error *e) {
    return helper(c, "tools", "tools/list", v ? "cursor" : NULL, v, NULL, r, e);
}
mcp_status mcp_tools_call(mcp_client *c, const char *v, const char *a, mcp_response *r, mcp_error *e) {
    return helper(c, "tools", "tools/call", "name", v, a ? a : "{}", r, e);
}
mcp_status mcp_resources_list(mcp_client *c, const char *v, mcp_response *r, mcp_error *e) {
    return helper(c, "resources", "resources/list", v ? "cursor" : NULL, v, NULL, r, e);
}
mcp_status mcp_resources_read(mcp_client *c, const char *v, mcp_response *r, mcp_error *e) {
    return helper(c, "resources", "resources/read", "uri", v, NULL, r, e);
}
mcp_status mcp_prompts_list(mcp_client *c, const char *v, mcp_response *r, mcp_error *e) {
    return helper(c, "prompts", "prompts/list", v ? "cursor" : NULL, v, NULL, r, e);
}
mcp_status mcp_prompts_get(mcp_client *c, const char *v, const char *a, mcp_response *r, mcp_error *e) {
    return helper(c, "prompts", "prompts/get", "name", v, a ? a : "{}", r, e);
}

static mcp_status wait_child(mcp_client *c, int *status, bool *exited, mcp_error *e) {
    int64_t d;
    mcp_status s = deadline_after(c->shutdown_ms, &d, e);
    if (s != MCP_OK) return s;
    for (;;) {
        pid_t rc = waitpid(c->pid, status, WNOHANG);
        if (rc == c->pid) { *exited = true; return MCP_OK; }
        if (rc < 0 && errno == EINTR) continue;
        if (rc < 0) {
            if (errno == ECHILD) *exited = true; /* caller reaped it; never signal a reused PID */
            return fail(e, MCP_SYSTEM_ERROR, errno, "waitpid MCP server");
        }
        int64_t now = now_ms();
        if (now < 0) return fail(e, MCP_SYSTEM_ERROR, errno, "clock_gettime");
        if (now >= d) return MCP_TIMEOUT;
        /* Drain shutdown output so an exiting server cannot fill its pipe. */
        char discard[4096];
        if (c->fd >= 0) {
            ssize_t n = recv(c->fd, discard, sizeof(discard), 0);
            if (n > 0) continue;
            if (n < 0 && errno != EAGAIN && errno != EWOULDBLOCK && errno != EINTR)
                return fail(e, MCP_SYSTEM_ERROR, errno, "drain MCP shutdown stream");
        }
        struct timespec pause = {0, 1000000};
        nanosleep(&pause, NULL);
    }
}

mcp_status mcp_client_close(mcp_client *c, mcp_error *e) {
    if (!c) return fail(e, MCP_OK, 0, "success");
    mcp_status s = MCP_OK;
    if (c->fd >= 0 && shutdown(c->fd, SHUT_WR) != 0 && errno != ENOTCONN)
        s = fail(e, MCP_SYSTEM_ERROR, errno, "close MCP server stdin");
    if (c->pid > 0) {
        int status = 0;
        bool exited = false, forced = false;
        mcp_error child_error = {0};
        mcp_status w = wait_child(c, &status, &exited, &child_error);
        if (w == MCP_SYSTEM_ERROR && s == MCP_OK) s = fail(e, w, child_error.system_errno, child_error.message);
        if (!exited) {
            forced = true;
            if (kill(c->pid, SIGTERM) != 0 && errno != ESRCH) w = fail(&child_error, MCP_SYSTEM_ERROR, errno, "SIGTERM MCP server");
            else w = wait_child(c, &status, &exited, &child_error);
        }
        if (w == MCP_SYSTEM_ERROR && s == MCP_OK) s = fail(e, w, child_error.system_errno, child_error.message);
        if (!exited) {
            if (kill(c->pid, SIGKILL) != 0 && errno != ESRCH) w = fail(&child_error, MCP_SYSTEM_ERROR, errno, "SIGKILL MCP server");
            else {
                pid_t rc;
                do { rc = waitpid(c->pid, &status, 0); } while (rc < 0 && errno == EINTR);
                if (rc < 0) w = fail(&child_error, MCP_SYSTEM_ERROR, errno, "reap MCP server");
                else { exited = true; w = MCP_OK; }
            }
        }
        if (s == MCP_OK) {
            if (w == MCP_SYSTEM_ERROR) s = fail(e, w, child_error.system_errno, child_error.message);
            else if (forced) s = fail(e, MCP_TIMEOUT, 0, "MCP server required forced shutdown");
            else if (exited && (!WIFEXITED(status) || WEXITSTATUS(status) != 0)) {
                s = fail(e, MCP_SYSTEM_ERROR, 0, "MCP server exited unsuccessfully");
                if (e) e->child_status = status;
            }
        }
    }
    if (c->fd >= 0 && close(c->fd) != 0 && s == MCP_OK) s = fail(e, MCP_SYSTEM_ERROR, errno, "close MCP stream");
    json_object_put(c->capabilities); free(c->buffer); free(c->name); free(c->version); free(c);
    return s == MCP_OK ? fail(e, MCP_OK, 0, "success") : s;
}
