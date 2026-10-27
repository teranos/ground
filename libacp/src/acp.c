#include "internal.h"

#include <stdio.h>
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

void acp_text_add(acp_text *t, const char *s, size_t n) {
    if (t->failed) return;
    if (t->length + n + 1 > t->capacity) {
        size_t capacity = t->capacity ? t->capacity : 256;
        while (capacity < t->length + n + 1) capacity *= 2;
        char *grown = realloc(t->data, capacity);
        if (grown == NULL) { t->failed = 1; return; }
        t->data = grown;
        t->capacity = capacity;
    }
    memcpy(t->data + t->length, s, n);
    t->length += n;
    t->data[t->length] = '\0';
}

void acp_text_puts(acp_text *t, const char *s) {
    acp_text_add(t, s, strlen(s));
}

void acp_text_printf(acp_text *t, const char *format, ...) {
    char small[128];
    va_list args;
    va_start(args, format);
    int n = vsnprintf(small, sizeof small, format, args);
    va_end(args);
    if (n < 0) { t->failed = 1; return; }
    if ((size_t) n < sizeof small) { acp_text_add(t, small, (size_t) n); return; }
    char *large = malloc((size_t) n + 1);
    if (large == NULL) { t->failed = 1; return; }
    va_start(args, format);
    vsnprintf(large, (size_t) n + 1, format, args);
    va_end(args);
    acp_text_add(t, large, (size_t) n);
    free(large);
}

void acp_text_json_string(acp_text *t, const char *s) {
    acp_text_add(t, "\"", 1);
    for (const unsigned char *c = (const unsigned char *) s; *c; c++) {
        switch (*c) {
        case '"': acp_text_add(t, "\\\"", 2); break;
        case '\\': acp_text_add(t, "\\\\", 2); break;
        case '\n': acp_text_add(t, "\\n", 2); break;
        case '\r': acp_text_add(t, "\\r", 2); break;
        case '\t': acp_text_add(t, "\\t", 2); break;
        default:
            if (*c < 0x20) acp_text_printf(t, "\\u%04x", *c);
            else acp_text_add(t, (const char *) c, 1);
        }
    }
    acp_text_add(t, "\"", 1);
}

acp_status acp_text_finish(acp_text *t, acp_buffer *out) {
    if (t->failed) {
        free(t->data);
        out->data = NULL;
        out->length = 0;
        return ACP_NO_MEMORY;
    }
    out->data = t->data;
    out->length = t->length;
    return ACP_OK;
}
