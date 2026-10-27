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

acp_status acp_directories_read(const char *params_json, size_t length, acp_buffer *list_json, acp_buffer *error_json) {
    if (params_json == NULL || list_json == NULL || error_json == NULL) return ACP_INVALID_ARGUMENT;
    list_json->data = NULL;
    list_json->length = 0;
    error_json->data = NULL;
    error_json->length = 0;
    json_object *params = acp_parse(params_json, length);
    json_object *named = acp_field(params, "additionalDirectories");
    acp_status status = ACP_OK;
    json_object *list = json_object_new_array();
    if (named != NULL && !json_object_is_type(named, json_type_array)) {
        status = acp_invalid(error_json, "additionalDirectories must be a list of paths");
    } else {
        size_t n = named ? json_object_array_length(named) : 0;
        for (size_t i = 0; i < n && status == ACP_OK; i++) {
            json_object *path = json_object_array_get_idx(named, i);
            if (!json_object_is_type(path, json_type_string)) {
                status = acp_invalid(error_json, "additionalDirectories must be a list of paths");
                break;
            }
            const char *s = json_object_get_string(path);
            // "Each path must be absolute."
            if (s[0] != '/') {
                char message[4200];
                snprintf(message, sizeof message, "additionalDirectories must be absolute paths: %s", s);
                status = acp_invalid(error_json, message);
                break;
            }
            json_object_array_add(list, json_object_new_string(s));
        }
    }
    json_object_put(params);
    if (status != ACP_OK) {
        json_object_put(list);
        return status;
    }
    return acp_finish(list, list_json);
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

// A field's string, copied, or NULL when absent or null; anything else is refused as not a string.
static acp_status optional_string(json_object *value, const char *key, char **out, acp_buffer *error_json) {
    if (value == NULL || json_object_is_type(value, json_type_null)) return ACP_OK;
    if (json_object_is_type(value, json_type_string)) {
        const char *s = json_object_get_string(value);
        size_t n = strlen(s) + 1;
        if ((*out = malloc(n)) == NULL) return ACP_NO_MEMORY;
        memcpy(*out, s, n);
        return ACP_OK;
    }
    char message[64];
    snprintf(message, sizeof message, "session/list's %s must be a string", key);
    return acp_invalid(error_json, message);
}

acp_status acp_session_list_read(const char *params_json, size_t length, acp_session_list *out, acp_buffer *error_json) {
    if (params_json == NULL || out == NULL || error_json == NULL) return ACP_INVALID_ARGUMENT;
    memset(out, 0, sizeof *out);
    error_json->data = NULL;
    error_json->length = 0;
    json_object *params = acp_parse(params_json, length);
    acp_status status = optional_string(acp_field(params, "cwd"), "cwd", &out->cwd, error_json);
    if (status == ACP_OK && out->cwd != NULL && out->cwd[0] != '/') {
        char message[4200];
        snprintf(message, sizeof message, "cwd must be an absolute path: %s", out->cwd);
        status = acp_invalid(error_json, message);
    }
    if (status == ACP_OK) status = optional_string(acp_field(params, "cursor"), "cursor", &out->cursor, error_json);
    json_object_put(params);
    if (status != ACP_OK) acp_session_list_free(out);
    return status;
}

void acp_session_list_free(acp_session_list *list) {
    if (list == NULL) return;
    free(list->cwd);
    free(list->cursor);
    list->cwd = NULL;
    list->cursor = NULL;
}

acp_status acp_session_info_write(const acp_session_info *info, acp_buffer *out_json) {
    if (info == NULL || info->session_id == NULL || info->cwd == NULL || out_json == NULL) return ACP_INVALID_ARGUMENT;
    json_object *dirs = NULL;
    if (info->additional_directories != NULL) {
        dirs = acp_parse(info->additional_directories, strlen(info->additional_directories));
        if (!json_object_is_type(dirs, json_type_array)) {
            json_object_put(dirs);
            return ACP_INVALID_ARGUMENT;
        }
    }
    json_object *entry = json_object_new_object();
    json_object_object_add(entry, "sessionId", json_object_new_string(info->session_id));
    json_object_object_add(entry, "cwd", json_object_new_string(info->cwd));
    // "Omitted and empty values are equivalent."
    if (dirs != NULL && json_object_array_length(dirs) > 0) json_object_object_add(entry, "additionalDirectories", dirs);
    else json_object_put(dirs);
    if (info->title != NULL && info->title[0] != '\0')
        json_object_object_add(entry, "title", json_object_new_string(info->title));
    if (info->updated_at != NULL) json_object_object_add(entry, "updatedAt", json_object_new_string(info->updated_at));
    return acp_finish(entry, out_json);
}
