// echo_server: an MCP server on stdio, at 2025-11-25, offering one tool, echo, that answers echoed.
// It refuses server/discover as a server from before 2026-07-28 does, so a client falls back.
#define _POSIX_C_SOURCE 200809L

#include <stdio.h>
#include <string.h>

// The text of a request's id, as it stands in the line, or NULL for a notification.
static const char *id_of(const char *line, size_t *length) {
    const char *at = strstr(line, "\"id\":");
    if (at == NULL) return NULL;
    at += 5;
    const char *end = at;
    if (*end == '"') {
        end++;
        while (*end && *end != '"') end += *end == '\\' && end[1] ? 2 : 1;
        if (*end) end++;
    } else {
        while (*end && *end != ',' && *end != '}') end++;
    }
    *length = (size_t) (end - at);
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

static void answer(const char *id, size_t length, const char *rest) {
    printf("{\"jsonrpc\":\"2.0\",\"id\":%.*s,%s}\n", (int) length, id, rest);
    fflush(stdout);
}

int main(void) {
    char *line = NULL;
    size_t capacity = 0;
    while (getline(&line, &capacity, stdin) >= 0) {
        size_t length = 0;
        const char *id = id_of(line, &length);
        if (id == NULL || strstr(line, "\"method\":") == NULL) continue;
        if (method_is(line, "server/discover"))
            answer(id, length, "\"error\":{\"code\":-32602,\"message\":\"initialize first\"}");
        else if (method_is(line, "initialize"))
            answer(id, length, "\"result\":{\"protocolVersion\":\"2025-11-25\",\"capabilities\":{\"tools\":{}},"
                               "\"serverInfo\":{\"name\":\"echo\",\"version\":\"1\"}}");
        else if (method_is(line, "tools/list"))
            answer(id, length, "\"result\":{\"tools\":[{\"name\":\"echo\",\"description\":\"Answers echoed\","
                               "\"inputSchema\":{\"type\":\"object\"}}]}");
        else if (method_is(line, "tools/call"))
            answer(id, length, "\"result\":{\"content\":[{\"type\":\"text\",\"text\":\"echoed\"}]}");
        else if (method_is(line, "ping"))
            answer(id, length, "\"result\":{}");
        else
            answer(id, length, "\"error\":{\"code\":-32601,\"message\":\"echo_server answers no such method\"}");
    }
    return 0;
}
