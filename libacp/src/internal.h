#ifndef ACP_INTERNAL_H
#define ACP_INTERNAL_H

#include "acp.h"

#include <stdarg.h>

// A growing string, the shape every buffer libacp hands out is written in.
typedef struct acp_text {
    char *data;
    size_t length;
    size_t capacity;
    int failed; // an allocation did not land; everything after it is dropped
} acp_text;

void acp_text_add(acp_text *t, const char *s, size_t n);
void acp_text_puts(acp_text *t, const char *s);
void acp_text_printf(acp_text *t, const char *format, ...);
// s as a JSON string, quotes included.
void acp_text_json_string(acp_text *t, const char *s);
// Hands t to out; ACP_NO_MEMORY when an allocation failed along the way.
acp_status acp_text_finish(acp_text *t, acp_buffer *out);

#endif
