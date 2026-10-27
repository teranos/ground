#include "internal.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

// A JSON-RPC -32602 for method's params, said as message.
static acp_status invalid(acp_buffer *error_json, const char *message) {
    json_object *error = json_object_new_object();
    json_object_object_add(error, "code", json_object_new_int(ACP_ERROR_INVALID_PARAMS));
    json_object_object_add(error, "message", json_object_new_string(message));
    acp_status written = acp_finish(error, error_json);
    return written == ACP_OK ? ACP_INVALID_PARAMS : written;
}

// A string field's value, copied, or NULL when absent or not a string.
static char *string_of(json_object *params, const char *key) {
    json_object *value = acp_field(params, key);
    if (!json_object_is_type(value, json_type_string)) return NULL;
    const char *s = json_object_get_string(value);
    size_t n = strlen(s) + 1;
    char *copy = malloc(n);
    if (copy != NULL) memcpy(copy, s, n);
    return copy;
}

acp_status acp_session_resume_read(const char *params_json, size_t length,
                                   acp_session_resume *out, acp_buffer *error_json) {
    if (params_json == NULL || out == NULL || error_json == NULL) return ACP_INVALID_ARGUMENT;
    memset(out, 0, sizeof *out);
    error_json->data = NULL;
    error_json->length = 0;

    json_object *params = acp_parse(params_json, length);
    acp_status status = ACP_OK;
    char message[1100];
    if (!json_object_is_type(params, json_type_object)) {
        status = invalid(error_json, "session/resume params are not a JSON object");
    } else if ((out->session_id = string_of(params, "sessionId")) == NULL) {
        status = invalid(error_json, "session/resume needs sessionId");
    } else if ((out->cwd = string_of(params, "cwd")) == NULL) {
        status = invalid(error_json, "session/resume needs cwd");
    } else if (out->cwd[0] != '/') {
        snprintf(message, sizeof message, "cwd must be an absolute path: %s", out->cwd);
        status = invalid(error_json, message);
    }
    json_object_put(params);
    if (status != ACP_OK) acp_session_resume_free(out);
    return status;
}

void acp_session_resume_free(acp_session_resume *resume) {
    if (resume == NULL) return;
    free(resume->session_id);
    free(resume->cwd);
    resume->session_id = NULL;
    resume->cwd = NULL;
}
