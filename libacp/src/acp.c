#include "internal.h"

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

// One JSON value, the whole of what was given, or NULL.
json_object *acp_parse(const char *json, size_t length) {
    if (json == NULL || length > INT32_MAX) return NULL;
    json_tokener *tokener = json_tokener_new();
    if (tokener == NULL) return NULL;
    json_object *value = json_tokener_parse_ex(tokener, json, (int) length);
    int whole = json_tokener_get_error(tokener) == json_tokener_success
        && (size_t) json_tokener_get_parse_end(tokener) == length;
    json_tokener_free(tokener);
    if (!whole) {
        json_object_put(value);
        return NULL;
    }
    return value;
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

int acp_flag(json_object *object, const char *key) {
    json_object *value = acp_field(object, key);
    return json_object_is_type(value, json_type_boolean) && json_object_get_boolean(value);
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
