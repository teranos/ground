// elicit_server: an MCP server on stdio whose tools ask the user through elicitation/create.
// ELICIT_PROTOCOL legacy asks with a request of its own; modern answers input_required, as 2026-07-28 does.
// Every request it reads, and every answer to its own, is written to ELICIT_LOG.
#define _POSIX_C_SOURCE 200809L

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static FILE *logged;

static const char form[] = "\"message\":\"Which branch?\",\"requestedSchema\":{\"type\":\"object\","
                           "\"properties\":{\"branch\":{\"type\":\"string\"}},\"required\":[\"branch\"]}";
static const char link[] = "\"mode\":\"url\",\"message\":\"Sign in\",\"elicitationId\":\"x1\",\"url\":\"https://example.com/sign-in\"";

// Where the JSON value starting at p ends: a string, an object or array with its nesting, or a scalar.
static const char *value_end(const char *p) {
    if (*p == '"') {
        for (p++; *p && *p != '"'; p += *p == '\\' && p[1] ? 2 : 1) {}
        return *p ? p + 1 : p;
    }
    if (*p == '{' || *p == '[') {
        int depth = 0;
        for (; *p; p++) {
            if (*p == '"') { p = value_end(p) - 1; continue; }
            if (*p == '{' || *p == '[') depth++;
            else if ((*p == '}' || *p == ']') && --depth == 0) return p + 1;
        }
        return p;
    }
    while (*p && *p != ',' && *p != '}' && *p != ']') p++;
    return p;
}

// The value key first names in line, as it stands, or NULL.
static const char *value_of(const char *line, const char *key, size_t *length) {
    char want[64];
    snprintf(want, sizeof want, "\"%s\":", key);
    const char *at = strstr(line, want);
    if (at == NULL) return NULL;
    at += strlen(want);
    *length = (size_t) (value_end(at) - at);
    return at;
}

// The method as the line spells it, each / as it is or as JSON may write it, \/.
static int method_is(const char *line, const char *method) {
    char want[64], escaped[96];
    snprintf(want, sizeof want, "\"method\":\"%s\"", method);
    size_t w = (size_t) snprintf(escaped, sizeof escaped, "\"method\":\"");
    for (const char *p = method; *p != '\0' && w + 3 < sizeof escaped; p++) {
        if (*p == '/') escaped[w++] = '\\';
        escaped[w++] = *p;
    }
    escaped[w++] = '"';
    escaped[w] = '\0';
    return strstr(line, want) != NULL || strstr(line, escaped) != NULL;
}

// The text as a JSON string's contents.
static void put_escaped(const char *s, size_t n) {
    for (size_t i = 0; i < n; i++) {
        if (s[i] == '\n') { fputs("\\n", stdout); continue; }
        if (s[i] == '"' || s[i] == '\\') putchar('\\');
        putchar(s[i]);
    }
}

static void note(const char *line) {
    if (logged == NULL) return;
    size_t n = strlen(line);
    fputs(line, logged);
    if (n == 0 || line[n - 1] != '\n') fputc('\n', logged);
    fflush(logged);
}

static void ask(const char *line, const char *id, size_t idn, char **reply, size_t *capacity) {
    int asking = strstr(line, "\"name\":\"ask\"") != NULL;
    printf("{\"jsonrpc\":\"2.0\",\"id\":\"%s\",\"method\":\"elicitation/create\",\"params\":{%s}}\n",
        asking ? "e1" : "e2", asking ? form : link);
    fflush(stdout);
    if (getline(reply, capacity, stdin) < 0) exit(1);
    note(*reply);
    if (!asking) printf("{\"jsonrpc\":\"2.0\",\"method\":\"notifications/elicitation/complete\",\"params\":{\"elicitationId\":\"x1\"}}\n");
    size_t n = 0;
    const char *said = value_of(*reply, "result", &n);
    if (said == NULL) said = value_of(*reply, "error", &n);
    printf("{\"jsonrpc\":\"2.0\",\"id\":%.*s,\"result\":{\"content\":[{\"type\":\"text\",\"text\":\"", (int) idn, id);
    if (said != NULL) put_escaped(said, n);
    printf("\"}]}}\n");
}

int main(void) {
    const char *protocol = getenv("ELICIT_PROTOCOL"), *path = getenv("ELICIT_LOG");
    int modern = protocol != NULL && strcmp(protocol, "modern") == 0;
    if (path != NULL) logged = fopen(path, "a");
    const char *complete = modern ? "\"resultType\":\"complete\"," : "";
    char *line = NULL, *reply = NULL;
    size_t capacity = 0, reply_capacity = 0, n = 0, idn = 0;
    while (getline(&line, &capacity, stdin) >= 0) {
        const char *id = value_of(line, "id", &idn);
        if (id == NULL || strstr(line, "\"method\":") == NULL) continue;
        note(line);
        if (method_is(line, "server/discover") && !modern) {
            printf("{\"jsonrpc\":\"2.0\",\"id\":%.*s,\"error\":{\"code\":-32601,\"message\":\"legacy\"}}\n", (int) idn, id);
        } else if (method_is(line, "server/discover")) {
            printf("{\"jsonrpc\":\"2.0\",\"id\":%.*s,\"result\":{%s\"supportedVersions\":[\"2026-07-28\"],"
                   "\"capabilities\":{\"tools\":{}}}}\n", (int) idn, id, complete);
        } else if (method_is(line, "initialize")) {
            printf("{\"jsonrpc\":\"2.0\",\"id\":%.*s,\"result\":{%s\"protocolVersion\":\"2025-06-18\","
                   "\"serverInfo\":{\"name\":\"elicit\",\"version\":\"1\"},\"capabilities\":{\"tools\":{}}}}\n", (int) idn, id, complete);
        } else if (method_is(line, "tools/list")) {
            printf("{\"jsonrpc\":\"2.0\",\"id\":%.*s,\"result\":{%s\"tools\":[{\"name\":\"ask\",\"inputSchema\":{\"type\":\"object\"}},"
                   "{\"name\":\"link\",\"inputSchema\":{\"type\":\"object\"}}]}}\n", (int) idn, id, complete);
        } else if (method_is(line, "tools/call") && modern) {
            const char *answered = value_of(line, "inputResponses", &n);
            if (answered == NULL) {
                printf("{\"jsonrpc\":\"2.0\",\"id\":%.*s,\"result\":{\"resultType\":\"input_required\",\"requestState\":\"s1\","
                       "\"inputRequests\":{\"q\":{\"method\":\"elicitation/create\",\"params\":{%s,\"mode\":\"form\"}}}}}\n",
                    (int) idn, id, form);
            } else {
                printf("{\"jsonrpc\":\"2.0\",\"id\":%.*s,\"result\":{\"resultType\":\"complete\",\"content\":[{\"type\":\"text\",\"text\":\"",
                    (int) idn, id);
                put_escaped(answered, n);
                printf("\"}]}}\n");
            }
        } else if (method_is(line, "tools/call")) {
            ask(line, id, idn, &reply, &reply_capacity);
        } else {
            printf("{\"jsonrpc\":\"2.0\",\"id\":%.*s,\"result\":{%s}}\n", (int) idn, id, modern ? "\"resultType\":\"complete\"" : "");
        }
        fflush(stdout);
    }
    free(line);
    free(reply);
    return 0;
}
