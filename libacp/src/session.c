#include "internal.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

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
        status = acp_invalid(error_json, "session/resume params are not a JSON object");
    } else if ((out->session_id = acp_string(params, "sessionId")) == NULL) {
        status = acp_invalid(error_json, "session/resume needs sessionId");
    } else if ((out->cwd = acp_string(params, "cwd")) == NULL) {
        status = acp_invalid(error_json, "session/resume needs cwd");
    } else if (out->cwd[0] != '/') {
        snprintf(message, sizeof message, "cwd must be an absolute path: %s", out->cwd);
        status = acp_invalid(error_json, message);
    }
    json_object_put(params);
    if (status != ACP_OK) acp_session_resume_free(out);
    return status;
}

acp_status acp_session_target_read(const char *method, const char *params_json, size_t length,
                                   char **session_id, acp_buffer *error_json) {
    if (method == NULL || params_json == NULL || session_id == NULL || error_json == NULL) return ACP_INVALID_ARGUMENT;
    *session_id = NULL;
    error_json->data = NULL;
    error_json->length = 0;
    json_object *params = acp_parse(params_json, length);
    acp_status status = ACP_OK;
    char message[256];
    if (!json_object_is_type(params, json_type_object) || (*session_id = acp_string(params, "sessionId")) == NULL) {
        snprintf(message, sizeof message, "%s needs sessionId", method);
        status = acp_invalid(error_json, message);
    }
    json_object_put(params);
    return status;
}

void acp_session_target_free(char **session_id) {
    if (session_id == NULL) return;
    free(*session_id);
    *session_id = NULL;
}

void acp_session_resume_free(acp_session_resume *resume) {
    if (resume == NULL) return;
    free(resume->session_id);
    free(resume->cwd);
    resume->session_id = NULL;
    resume->cwd = NULL;
}
