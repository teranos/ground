#include "internal.h"

#include <stdlib.h>
#include <string.h>

static void add_string(json_object *object, const char *key, const char *value) {
    if (value != NULL) json_object_object_add(object, key, json_object_new_string(value));
}

acp_status acp_session_update_write(const char *session_id, const char *update_json, acp_buffer *message_json) {
    if (session_id == NULL || update_json == NULL || message_json == NULL) return ACP_INVALID_ARGUMENT;
    // The update as it was written, byte for byte: what it carries raw stays raw.
    json_object *update = acp_raw(update_json);
    if (!json_object_is_type(update, json_type_object)) {
        json_object_put(update);
        return update == NULL ? ACP_NO_MEMORY : ACP_INVALID_ARGUMENT;
    }
    json_object *params = json_object_new_object();
    add_string(params, "sessionId", session_id);
    json_object_object_add(params, "update", update);
    json_object *message = json_object_new_object();
    add_string(message, "jsonrpc", "2.0");
    json_object_object_add(message, "method", json_object_new_string(ACP_CLIENT_SESSION_UPDATE));
    json_object_object_add(message, "params", params);
    return acp_finish(message, message_json);
}

acp_status acp_text_chunk_write(acp_chunk_kind kind, const char *text, size_t length, acp_buffer *update_json) {
    static const char *const named[] = {"agent_message_chunk", "agent_thought_chunk", "user_message_chunk"};
    if (text == NULL || update_json == NULL || (unsigned) kind >= sizeof named / sizeof *named || length > INT32_MAX)
        return ACP_INVALID_ARGUMENT;
    json_object *content = json_object_new_object();
    add_string(content, "type", "text");
    json_object_object_add(content, "text", json_object_new_string_len(text, (int) length));
    json_object *update = json_object_new_object();
    add_string(update, "sessionUpdate", named[kind]);
    json_object_object_add(update, "content", content);
    return acp_finish(update, update_json);
}

acp_status acp_image_chunk_write(acp_chunk_kind kind, const char *mime_type, const char *data, acp_buffer *update_json) {
    static const char *const named[] = {"agent_message_chunk", "agent_thought_chunk", "user_message_chunk"};
    if (mime_type == NULL || data == NULL || update_json == NULL || (unsigned) kind >= sizeof named / sizeof *named)
        return ACP_INVALID_ARGUMENT;
    json_object *content = json_object_new_object();
    add_string(content, "type", "image");
    add_string(content, "mimeType", mime_type);
    add_string(content, "data", data);
    json_object *update = json_object_new_object();
    add_string(update, "sessionUpdate", named[kind]);
    json_object_object_add(update, "content", content);
    return acp_finish(update, update_json);
}

// ToolCallContent: the terminal when there is one, then each block written as content, or the text as one
// text block when there are none.
static json_object *tool_content(const char *terminal_id, const char *blocks_json, const char *text, int *bad) {
    json_object *blocks = NULL;
    if (blocks_json != NULL) {
        blocks = acp_parse(blocks_json, strlen(blocks_json));
        if (!json_object_is_type(blocks, json_type_array)) {
            json_object_put(blocks);
            *bad = 1;
            return NULL;
        }
    }
    json_object *content = NULL;
    if (terminal_id != NULL) {
        json_object *terminal = json_object_new_object();
        add_string(terminal, "type", "terminal");
        add_string(terminal, "terminalId", terminal_id);
        content = json_object_new_array();
        json_object_array_add(content, terminal);
    }
    size_t n = blocks != NULL ? json_object_array_length(blocks) : 0;
    if (n > 0) {
        if (content == NULL) content = json_object_new_array();
        for (size_t i = 0; i < n; i++) {
            json_object *item = json_object_new_object();
            add_string(item, "type", "content");
            json_object_object_add(item, "content", json_object_get(json_object_array_get_idx(blocks, i)));
            json_object_array_add(content, item);
        }
    } else if (text != NULL && text[0] != '\0') {
        json_object *block = json_object_new_object();
        add_string(block, "type", "text");
        add_string(block, "text", text);
        json_object *item = json_object_new_object();
        add_string(item, "type", "content");
        json_object_object_add(item, "content", block);
        if (content == NULL) content = json_object_new_array();
        json_object_array_add(content, item);
    }
    json_object_put(blocks);
    return content;
}

acp_status acp_tool_call_write(const acp_tool_call *call, acp_buffer *update_json) {
    if (call == NULL || update_json == NULL || call->tool_call_id == NULL) return ACP_INVALID_ARGUMENT;
    int bad = 0;
    json_object *content = tool_content(call->terminal_id, call->content_blocks, call->content_text, &bad);
    if (bad) return ACP_INVALID_ARGUMENT;
    json_object *update = json_object_new_object();
    add_string(update, "sessionUpdate", call->update ? "tool_call_update" : "tool_call");
    add_string(update, "toolCallId", call->tool_call_id);
    add_string(update, "title", call->title);
    add_string(update, "name", call->name);
    add_string(update, "kind", call->kind);
    add_string(update, "status", call->status);
    if (call->raw_input != NULL) json_object_object_add(update, "rawInput", acp_raw(call->raw_input));
    if (call->raw_output != NULL) json_object_object_add(update, "rawOutput", acp_raw(call->raw_output));
    if (content != NULL) json_object_object_add(update, "content", content);
    return acp_finish(update, update_json);
}

acp_status acp_usage_update_write(unsigned long long used, unsigned long long size, const char *cost_amount,
    const char *currency, acp_buffer *update_json) {
    if (update_json == NULL || used > INT64_MAX || size > INT64_MAX) return ACP_INVALID_ARGUMENT;
    json_object *amount = NULL;
    if (cost_amount != NULL) {
        // The amount as the caller wrote it, so its digits are its own.
        json_object *read = acp_parse(cost_amount, strlen(cost_amount));
        int number = json_object_is_type(read, json_type_double) || json_object_is_type(read, json_type_int);
        double value = number ? json_object_get_double(read) : 0;
        json_object_put(read);
        if (!number || currency == NULL) return ACP_INVALID_ARGUMENT;
        amount = json_object_new_double_s(value, cost_amount);
    }
    json_object *update = json_object_new_object();
    add_string(update, "sessionUpdate", "usage_update");
    json_object_object_add(update, "used", json_object_new_int64((int64_t) used));
    json_object_object_add(update, "size", json_object_new_int64((int64_t) size));
    if (amount != NULL) {
        json_object *cost = json_object_new_object();
        json_object_object_add(cost, "amount", amount);
        add_string(cost, "currency", currency);
        json_object_object_add(update, "cost", cost);
    }
    return acp_finish(update, update_json);
}

acp_status acp_session_info_update_write(const char *title, const char *updated_at, acp_buffer *update_json) {
    if (updated_at == NULL || update_json == NULL) return ACP_INVALID_ARGUMENT;
    json_object *update = json_object_new_object();
    add_string(update, "sessionUpdate", "session_info_update");
    add_string(update, "title", title);
    add_string(update, "updatedAt", updated_at);
    return acp_finish(update, update_json);
}

acp_status acp_session_title_clear_write(const char *updated_at, acp_buffer *update_json) {
    if (updated_at == NULL || update_json == NULL) return ACP_INVALID_ARGUMENT;
    json_object *update = json_object_new_object();
    add_string(update, "sessionUpdate", "session_info_update");
    json_object_object_add(update, "title", NULL);
    add_string(update, "updatedAt", updated_at);
    return acp_finish(update, update_json);
}

acp_status acp_available_commands_update_write(const char *commands_json, acp_buffer *update_json) {
    if (commands_json == NULL || update_json == NULL) return ACP_INVALID_ARGUMENT;
    json_object *commands = acp_parse(commands_json, strlen(commands_json));
    if (!json_object_is_type(commands, json_type_array)) {
        json_object_put(commands);
        return ACP_INVALID_ARGUMENT;
    }
    json_object *update = json_object_new_object();
    add_string(update, "sessionUpdate", "available_commands_update");
    json_object_object_add(update, "availableCommands", commands);
    return acp_finish(update, update_json);
}

acp_status acp_notice_write(const char *severity, const char *title, const char *description, acp_buffer *update_json) {
    if (severity == NULL || title == NULL || description == NULL || update_json == NULL) return ACP_INVALID_ARGUMENT;
    json_object *update = json_object_new_object();
    add_string(update, "sessionUpdate", "notice");
    add_string(update, "severity", severity);
    add_string(update, "title", title);
    add_string(update, "description", description);
    return acp_finish(update, update_json);
}

acp_status acp_elicitation_create_write(const char *request_id, const char *session_id, const char *tool_call_id,
    const char *server_params, size_t length, int *mode, acp_buffer *message_json) {
    if (request_id == NULL || session_id == NULL || tool_call_id == NULL || server_params == NULL || mode == NULL
        || message_json == NULL) return ACP_INVALID_ARGUMENT;
    message_json->data = NULL;
    message_json->length = 0;
    json_object *asked = acp_parse(server_params, length);
    json_object *named = acp_field(asked, "mode");
    if (!json_object_is_type(asked, json_type_object) || (named != NULL && !json_object_is_type(named, json_type_string))) {
        json_object_put(asked);
        return ACP_INVALID_PARAMS;
    }
    json_object *id = acp_parse(request_id, strlen(request_id));
    if (id == NULL) {
        json_object_put(asked);
        return ACP_INVALID_ARGUMENT;
    }
    const char *how = named != NULL ? json_object_get_string(named) : "form";
    *mode = strcmp(how, "form") == 0 ? ACP_ELICIT_FORM : strcmp(how, "url") == 0 ? ACP_ELICIT_URL : ACP_ELICIT_OTHER;
    json_object *params = json_object_new_object();
    add_string(params, "sessionId", session_id);
    add_string(params, "toolCallId", tool_call_id);
    add_string(params, "mode", how);
    // "message", required, as the server gave it; then the rest of what it asked.
    json_object *message_text = acp_field(asked, "message");
    if (message_text != NULL) json_object_object_add(params, "message", json_object_get(message_text));
    json_object_object_foreach(asked, key, value) {
        if (strcmp(key, "mode") == 0 || strcmp(key, "sessionId") == 0 || strcmp(key, "toolCallId") == 0
            || strcmp(key, "message") == 0) continue;
        json_object_object_add(params, key, json_object_get(value));
    }
    json_object_put(asked);
    json_object *message = json_object_new_object();
    add_string(message, "jsonrpc", "2.0");
    json_object_object_add(message, "id", id);
    json_object_object_add(message, "method", json_object_new_string(ACP_CLIENT_ELICITATION_CREATE));
    json_object_object_add(message, "params", params);
    return acp_finish(message, message_json);
}

acp_status acp_elicitation_url_write(const char *id, const char *request_id, const char *elicitation_id,
    const char *url, const char *message, acp_buffer *message_json) {
    if (id == NULL || request_id == NULL || elicitation_id == NULL || url == NULL || message == NULL || message_json == NULL)
        return ACP_INVALID_ARGUMENT;
    message_json->data = NULL;
    message_json->length = 0;
    json_object *own = acp_parse(id, strlen(id));
    json_object *scope = acp_parse(request_id, strlen(request_id));
    if (own == NULL || scope == NULL) {
        json_object_put(own);
        json_object_put(scope);
        return ACP_INVALID_ARGUMENT;
    }
    json_object *params = json_object_new_object();
    json_object_object_add(params, "requestId", scope);
    add_string(params, "mode", "url");
    add_string(params, "message", message);
    add_string(params, "elicitationId", elicitation_id);
    add_string(params, "url", url);
    json_object *m = json_object_new_object();
    add_string(m, "jsonrpc", "2.0");
    json_object_object_add(m, "id", own);
    json_object_object_add(m, "method", json_object_new_string(ACP_CLIENT_ELICITATION_CREATE));
    json_object_object_add(m, "params", params);
    return acp_finish(m, message_json);
}

acp_status acp_elicitation_complete_write(const char *elicitation_id, acp_buffer *message_json) {
    if (elicitation_id == NULL || message_json == NULL) return ACP_INVALID_ARGUMENT;
    json_object *params = json_object_new_object();
    add_string(params, "elicitationId", elicitation_id);
    json_object *message = json_object_new_object();
    add_string(message, "jsonrpc", "2.0");
    json_object_object_add(message, "method", json_object_new_string(ACP_CLIENT_ELICITATION_COMPLETE));
    json_object_object_add(message, "params", params);
    return acp_finish(message, message_json);
}
