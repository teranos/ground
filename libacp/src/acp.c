#include "internal.h"

#include <json-c/printbuf.h>

#include <stdint.h>
#include <stdlib.h>
#include <string.h>

const char *acp_version(void) {
    return ACP_VERSION;
}

const char *acp_status_string(acp_status status) {
    switch (status) {
    case ACP_OK: return "ok";
    case ACP_INVALID_ARGUMENT: return "invalid argument";
    case ACP_NO_MEMORY: return "out of memory";
    case ACP_PARSE_ERROR: return "parse error";
    case ACP_INVALID_PARAMS: return "invalid params";
    case ACP_UNSUPPORTED_VERSION: return "unsupported protocol version";
    }
    return "unknown status";
}

void acp_buffer_free(acp_buffer *buffer) {
    if (buffer == NULL) return;
    free(buffer->data);
    buffer->data = NULL;
    buffer->length = 0;
}

// One JSON value, the whole of what was given; *ok says whether it was, as JSON null is NULL.
static json_object *parse_whole(const char *json, size_t length, int *ok) {
    *ok = 0;
    if (json == NULL || length > INT32_MAX) return NULL;
    json_tokener *tokener = json_tokener_new();
    if (tokener == NULL) return NULL;
    json_object *value = json_tokener_parse_ex(tokener, json, (int) length);
    int whole = json_tokener_get_error(tokener) == json_tokener_success
        && (size_t) json_tokener_get_parse_end(tokener) == length;
    // A number at the end of the text may yet go on: a NUL ends it, as it ends a C string.
    if (value == NULL && json_tokener_get_error(tokener) == json_tokener_continue) {
        value = json_tokener_parse_ex(tokener, "", 1);
        whole = json_tokener_get_error(tokener) == json_tokener_success;
    }
    json_tokener_free(tokener);
    if (!whole) {
        json_object_put(value);
        return NULL;
    }
    *ok = 1;
    return value;
}

// 「[Opus 5.5] RFC 8259's grammar, read from *p: what json-c would also take that JSON is not (single quotes,」
// 「[Opus 5.5] NaN, comments, a trailing comma) is refused. Each reader moves *p past what it read, or answers 0.」
static void skip_ws(const char **p) {
    while (**p == ' ' || **p == '\t' || **p == '\n' || **p == '\r') (*p)++;
}

static int json_value(const char **p, int depth);

static int json_string(const char **p) {
    if (**p != '"') return 0;
    (*p)++;
    while (**p != '"') {
        unsigned char c = (unsigned char) **p;
        if (c == 0 || c < 0x20) return 0;
        if (c == '\\') {
            (*p)++;
            if (**p == 'u') {
                for (int i = 1; i <= 4; i++) {
                    char h = (*p)[i];
                    if (!((h >= '0' && h <= '9') || (h >= 'a' && h <= 'f') || (h >= 'A' && h <= 'F'))) return 0;
                }
                *p += 5;
                continue;
            }
            if (strchr("\"\\/bfnrt", **p) == NULL || **p == 0) return 0;
        }
        (*p)++;
    }
    (*p)++;
    return 1;
}

static int json_number(const char **p) {
    const char *s = *p;
    if (*s == '-') s++;
    if (*s == '0') s++;
    else if (*s >= '1' && *s <= '9') while (*s >= '0' && *s <= '9') s++;
    else return 0;
    if (*s == '.') {
        s++;
        if (!(*s >= '0' && *s <= '9')) return 0;
        while (*s >= '0' && *s <= '9') s++;
    }
    if (*s == 'e' || *s == 'E') {
        s++;
        if (*s == '+' || *s == '-') s++;
        if (!(*s >= '0' && *s <= '9')) return 0;
        while (*s >= '0' && *s <= '9') s++;
    }
    *p = s;
    return 1;
}

static int json_value(const char **p, int depth) {
    if (depth > 512) return 0;
    skip_ws(p);
    char c = **p;
    if (c == '"') return json_string(p);
    if (c == '-' || (c >= '0' && c <= '9')) return json_number(p);
    if (strncmp(*p, "true", 4) == 0) { *p += 4; return 1; }
    if (strncmp(*p, "false", 5) == 0) { *p += 5; return 1; }
    if (strncmp(*p, "null", 4) == 0) { *p += 4; return 1; }
    if (c == '[' || c == '{') {
        char close = c == '[' ? ']' : '}';
        (*p)++;
        skip_ws(p);
        if (**p == close) { (*p)++; return 1; }
        for (;;) {
            if (close == '}') {
                skip_ws(p);
                if (!json_string(p)) return 0;
                skip_ws(p);
                if (**p != ':') return 0;
                (*p)++;
            }
            if (!json_value(p, depth + 1)) return 0;
            skip_ws(p);
            if (**p == ',') { (*p)++; continue; }
            if (**p == close) { (*p)++; return 1; }
            return 0;
        }
    }
    return 0;
}

// 「[Opus 5.5] Whether text is one JSON value, whole, as RFC 8259 writes one.」
static int rfc8259(const char *text) {
    const char *p = text;
    if (!json_value(&p, 0)) return 0;
    skip_ws(&p);
    return *p == 0;
}

// One JSON value, the whole of what was given, or NULL.
json_object *acp_parse(const char *json, size_t length) {
    int ok;
    return parse_whole(json, length, &ok);
}

json_object *acp_field(json_object *object, const char *key) {
    json_object *value = NULL;
    if (!json_object_is_type(object, json_type_object)) return NULL;
    return json_object_object_get_ex(object, key, &value) ? value : NULL;
}

// Present as an object, as {} offers form or url elicitation and session notices.
int acp_offered(json_object *object, const char *key) {
    return json_object_is_type(acp_field(object, key), json_type_object);
}

// A string field's value, copied, or NULL when absent, not a string, or holding a NUL, which
// would make it another, shorter string; the caller frees it.
char *acp_string(json_object *object, const char *key) {
    json_object *value = acp_field(object, key);
    if (!json_object_is_type(value, json_type_string)) return NULL;
    const char *s = json_object_get_string(value);
    if (strlen(s) != (size_t) json_object_get_string_len(value)) return NULL;
    size_t n = strlen(s) + 1;
    char *copy = malloc(n);
    if (copy != NULL) memcpy(copy, s, n);
    return copy;
}

int acp_flag(json_object *object, const char *key) {
    json_object *value = acp_field(object, key);
    return json_object_is_type(value, json_type_boolean) && json_object_get_boolean(value);
}

acp_status acp_invalid(acp_buffer *error_json, const char *message) {
    json_object *error = json_object_new_object();
    json_object_object_add(error, "code", json_object_new_int(ACP_ERROR_INVALID_PARAMS));
    json_object_object_add(error, "message", json_object_new_string(message));
    acp_status written = acp_finish(error, error_json);
    return written == ACP_OK ? ACP_INVALID_PARAMS : written;
}

acp_status acp_finish(json_object *object, acp_buffer *out) {
    out->data = NULL;
    out->length = 0;
    if (object == NULL) return ACP_NO_MEMORY;
    size_t length = 0;
    const char *json = json_object_to_json_string_length(object, JSON_C_TO_STRING_PLAIN | JSON_C_TO_STRING_NOSLASHESCAPE, &length);
    char *copy = json ? malloc(length + 1) : NULL;
    if (copy != NULL) {
        memcpy(copy, json, length + 1);
        out->data = copy;
        out->length = length;
    }
    json_object_put(object);
    return copy ? ACP_OK : ACP_NO_MEMORY;
}

// A raw value's serializer: the text it was made from, every byte as the caller gave it.
static int raw_text(json_object *object, struct printbuf *buffer, int level, int flags) {
    (void) level;
    (void) flags;
    const char *text = json_object_get_userdata(object);
    return printbuf_memappend(buffer, text, (int) strlen(text));
}

static void raw_free(json_object *object, void *userdata) {
    (void) object;
    free(userdata);
}

int acp_raw(const char *text, json_object **out) {
    *out = NULL;
    if (text == NULL || strlen(text) > INT32_MAX) return 0;
    int ok;
    // 「[Opus 5.5] What only a lenient reader takes for JSON (single quotes, NaN, comments) is the text it is:」
    // 「[Opus 5.5] written as it came, it is JSON no client can read.」
    json_object *value = rfc8259(text) ? parse_whole(text, strlen(text), &ok) : (ok = 0, NULL);
    if (!ok) return (*out = json_object_new_string(text)) != NULL;
    // JSON null is json-c's NULL; and a message is one line, so text over lines is written again.
    if (value == NULL || strpbrk(text, "\r\n") != NULL) {
        *out = value;
        return 1;
    }
    size_t n = strlen(text) + 1;
    char *copy = malloc(n);
    if (copy == NULL) {
        json_object_put(value);
        return 0;
    }
    memcpy(copy, text, n);
    json_object_set_serializer(value, raw_text, copy, raw_free);
    *out = value;
    return 1;
}

json_object *acp_locations(const acp_location *locations, size_t count, int *bad) {
    if (count == 0) return NULL;
    if (locations == NULL) {
        *bad = 1;
        return NULL;
    }
    for (size_t i = 0; i < count; i++)
        if (locations[i].path == NULL || locations[i].path[0] != '/') {
            *bad = 1;
            return NULL;
        }
    json_object *all = json_object_new_array();
    for (size_t i = 0; i < count; i++) {
        json_object *at = json_object_new_object();
        json_object_object_add(at, "path", json_object_new_string(locations[i].path));
        if (locations[i].line != 0) json_object_object_add(at, "line", json_object_new_int64(locations[i].line));
        json_object_array_add(all, at);
    }
    return all;
}
