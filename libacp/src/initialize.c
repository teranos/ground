#include "internal.h"

#include <json-c/json.h>
#include <string.h>

// ProtocolVersion is a uint16 in both schemas.
#define ACP_VERSION_MAX 65535

static json_object *field(json_object *object, const char *key) {
    json_object *value = NULL;
    if (object == NULL || !json_object_is_type(object, json_type_object)) return NULL;
    return json_object_object_get_ex(object, key, &value) ? value : NULL;
}

// Present as an object, as {} offers form or url elicitation and session notices.
static int offered(json_object *object, const char *key) {
    return json_object_is_type(field(object, key), json_type_object);
}

static int flag(json_object *object, const char *key) {
    json_object *value = field(object, key);
    return json_object_is_type(value, json_type_boolean) && json_object_get_boolean(value);
}

static void read_capabilities(json_object *params, unsigned requested, acp_client_capabilities *caps) {
    memset(caps, 0, sizeof *caps);
    // The request is in the shape of the version the client asked for.
    json_object *c = field(params, requested >= 2 ? "capabilities" : "clientCapabilities");
    json_object *elicitation = field(c, "elicitation");
    caps->elicitation_form = offered(elicitation, "form");
    caps->elicitation_url = offered(elicitation, "url");
    if (requested >= 2) return;
    json_object *fs = field(c, "fs");
    caps->fs_read_text_file = flag(fs, "readTextFile");
    caps->fs_write_text_file = flag(fs, "writeTextFile");
    caps->terminal = flag(c, "terminal");
    caps->session_notices = offered(field(c, "session"), "notices");
}

static acp_status invalid(acp_buffer *error_json, const char *message) {
    acp_text t = {0};
    acp_text_printf(&t, "{\"code\":%d,\"message\":", ACP_ERROR_INVALID_PARAMS);
    acp_text_json_string(&t, message);
    acp_text_puts(&t, "}");
    acp_status written = acp_text_finish(&t, error_json);
    return written == ACP_OK ? ACP_INVALID_PARAMS : written;
}

static acp_status unsupported(acp_buffer *error_json, unsigned requested, const unsigned *supported, size_t n) {
    acp_text t = {0};
    acp_text_printf(&t, "{\"code\":%d,\"message\":\"no supported protocol version is at or below %u\","
                        "\"data\":{\"requested\":%u,\"supported\":[",
                    ACP_ERROR_UNSUPPORTED_VERSION, requested, requested);
    // Listed in ascending order, whatever order the caller named them in.
    unsigned last = 0;
    for (size_t listed = 0; listed < n; listed++) {
        unsigned next = 0;
        for (size_t i = 0; i < n; i++)
            if (supported[i] > last && (next == 0 || supported[i] < next)) next = supported[i];
        if (next == 0) break;
        acp_text_printf(&t, listed ? ",%u" : "%u", next);
        last = next;
    }
    acp_text_puts(&t, "]}}");
    acp_status written = acp_text_finish(&t, error_json);
    return written == ACP_OK ? ACP_UNSUPPORTED_VERSION : written;
}

acp_status acp_initialize_read(const char *params_json, size_t length,
                               const unsigned *supported, size_t supported_count,
                               acp_initialize *out, acp_buffer *error_json) {
    if (params_json == NULL || supported == NULL || supported_count == 0 || out == NULL || error_json == NULL)
        return ACP_INVALID_ARGUMENT;
    memset(out, 0, sizeof *out);
    error_json->data = NULL;
    error_json->length = 0;

    json_tokener *tokener = json_tokener_new();
    if (tokener == NULL) return ACP_NO_MEMORY;
    json_object *params = json_tokener_parse_ex(tokener, params_json, (int) length);
    int parsed = json_tokener_get_error(tokener) == json_tokener_success && json_object_is_type(params, json_type_object);
    json_tokener_free(tokener);
    if (!parsed) {
        json_object_put(params);
        return invalid(error_json, "initialize params are not a JSON object");
    }

    json_object *version = field(params, "protocolVersion");
    if (!json_object_is_type(version, json_type_int)) {
        json_object_put(params);
        return invalid(error_json, "initialize params name no protocolVersion");
    }
    int64_t requested = json_object_get_int64(version);
    if (requested < 0 || requested > ACP_VERSION_MAX) {
        json_object_put(params);
        return invalid(error_json, "protocolVersion is not a uint16");
    }
    out->requested_version = (unsigned) requested;

    // The highest supported at or below what was requested.
    for (size_t i = 0; i < supported_count; i++)
        if (supported[i] <= out->requested_version && supported[i] > out->selected_version)
            out->selected_version = supported[i];

    read_capabilities(params, out->requested_version, &out->capabilities);
    json_object_put(params);
    if (out->selected_version == 0)
        return unsupported(error_json, out->requested_version, supported, supported_count);
    return ACP_OK;
}

// Caller JSON goes in whole, so it must be one JSON value of the expected type.
static int valid(const char *json, json_type expected) {
    json_tokener *tokener = json_tokener_new();
    if (tokener == NULL) return 0;
    json_object *value = json_tokener_parse_ex(tokener, json, (int) strlen(json));
    int ok = json_tokener_get_error(tokener) == json_tokener_success && json_object_is_type(value, expected);
    json_tokener_free(tokener);
    json_object_put(value);
    return ok;
}

acp_status acp_initialize_result(unsigned selected_version,
                                 const char *agent_name, const char *agent_version,
                                 const char *agent_capabilities_json,
                                 const char *auth_methods_json,
                                 acp_buffer *result_json) {
    if (result_json == NULL || agent_name == NULL || agent_version == NULL || selected_version == 0 || selected_version > 2)
        return ACP_INVALID_ARGUMENT;
    const char *capabilities = agent_capabilities_json ? agent_capabilities_json : "{}";
    const char *auth = auth_methods_json ? auth_methods_json : "[]";
    if (!valid(capabilities, json_type_object) || !valid(auth, json_type_array)) return ACP_INVALID_ARGUMENT;

    acp_text t = {0};
    acp_text_printf(&t, "{\"protocolVersion\":%u,", selected_version);
    if (selected_version >= 2) {
        acp_text_puts(&t, "\"info\":{\"name\":");
        acp_text_json_string(&t, agent_name);
        acp_text_puts(&t, ",\"version\":");
        acp_text_json_string(&t, agent_version);
        acp_text_puts(&t, "},\"capabilities\":");
        acp_text_puts(&t, capabilities);
        acp_text_puts(&t, ",\"authMethods\":");
        acp_text_puts(&t, auth);
        acp_text_puts(&t, "}");
    } else {
        acp_text_puts(&t, "\"agentCapabilities\":");
        acp_text_puts(&t, capabilities);
        acp_text_puts(&t, ",\"authMethods\":");
        acp_text_puts(&t, auth);
        acp_text_puts(&t, ",\"agentInfo\":{\"name\":");
        acp_text_json_string(&t, agent_name);
        acp_text_puts(&t, ",\"version\":");
        acp_text_json_string(&t, agent_version);
        acp_text_puts(&t, "}}");
    }
    return acp_text_finish(&t, result_json);
}
