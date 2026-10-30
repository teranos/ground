module libacp;

// The C ABI declared in libacp/include/acp.h. No druntime and no GC ownership.
// acp_buffer.data is freed by acp_buffer_free.

enum ACP_VERSION = "0.1.0-dev";

import core.stdc.config : c_ulong;

extern (C) nothrow @nogc {
    enum acp_status : int {
        ACP_OK = 0, ACP_INVALID_ARGUMENT, ACP_NO_MEMORY, ACP_PARSE_ERROR,
        ACP_INVALID_PARAMS, ACP_UNSUPPORTED_VERSION
    }

    struct acp_buffer { char* data; size_t length; }

    struct acp_client_capabilities {
        int fs_read_text_file;
        int fs_write_text_file;
        int terminal;
        int session_notices;
        int elicitation_form;
        int elicitation_url;
        int auth_terminal;
    }

    struct acp_initialize {
        uint requested_version;
        uint selected_version;
        acp_client_capabilities capabilities;
    }

    struct acp_session_new {
        char* cwd;
        acp_buffer additional_directories;
    }

    acp_status acp_session_new_read(const(char)* params_json, size_t length,
        acp_session_new* out_, acp_buffer* error_json);
    void acp_session_new_free(acp_session_new* session);
    acp_status acp_session_new_result(const(char)* session_id, const(char)* modes_json,
        const(char)* config_options_json, acp_buffer* out_json);

    struct acp_session_resume {
        char* session_id;
        char* cwd;
    }

    struct acp_session_list {
        char* cwd;
        char* cursor;
    }

    struct acp_session_info {
        const(char)* session_id;
        const(char)* cwd;
        const(char)* additional_directories;
        const(char)* title;
        const(char)* updated_at;
    }

    enum acp_block_kind : int {
        ACP_BLOCK_TEXT, ACP_BLOCK_RESOURCE_LINK, ACP_BLOCK_RESOURCE, ACP_BLOCK_OTHER, ACP_BLOCK_IMAGE
    }

    struct acp_prompt_block {
        acp_block_kind kind;
        char* type;
        char* text;
        char* name;
        char* uri;
        int holds_blob;
        char* mime_type;
        char* data;
    }

    struct acp_prompt {
        acp_prompt_block* blocks;
        size_t count;
    }

    enum acp_cancel_kind : int { ACP_CANCEL_NONE, ACP_CANCEL_SESSION, ACP_CANCEL_REQUEST }

    struct acp_cancel {
        acp_cancel_kind kind;
        char* session_id;
        char* request_id;
    }

    struct acp_permission_option {
        const(char)* option_id;
        const(char)* name;
        const(char)* kind;
    }

    struct acp_permission_request {
        const(char)* request_id;
        const(char)* session_id;
        const(char)* tool_call_id;
        const(char)* title;
        const(char)* name;
        const(char)* kind;
        const(char)* status;
        const(char)* raw_input;
        const(acp_permission_option)* options;
        size_t count;
    }

    enum acp_permission_kind : int { ACP_PERMISSION_UNREAD, ACP_PERMISSION_SELECTED, ACP_PERMISSION_CANCELLED }

    struct acp_permission_outcome {
        acp_permission_kind kind;
        char* option_id;
    }

    struct acp_text_file {
        char* content;
        size_t length;
    }

    struct acp_terminal_exit {
        int exited;
        int has_exit_code;
        c_ulong exit_code;
        char* signal;
    }

    struct acp_terminal_output {
        char* output;
        size_t length;
        int truncated;
        acp_terminal_exit exit_status;
    }

    enum acp_stop_reason : int {
        ACP_STOP_END_TURN, ACP_STOP_MAX_TOKENS, ACP_STOP_MAX_TURN_REQUESTS, ACP_STOP_REFUSAL, ACP_STOP_CANCELLED
    }

    enum acp_chunk_kind : int { ACP_CHUNK_AGENT_MESSAGE, ACP_CHUNK_AGENT_THOUGHT, ACP_CHUNK_USER_MESSAGE }

    struct acp_tool_call {
        int update;
        const(char)* tool_call_id;
        const(char)* title;
        const(char)* name;
        const(char)* kind;
        const(char)* status;
        const(char)* raw_input;
        const(char)* raw_output;
        const(char)* content_blocks;
        const(char)* content_text;
        const(char)* terminal_id;
    }

    enum acp_elicit_mode : int { ACP_ELICIT_FORM, ACP_ELICIT_URL, ACP_ELICIT_OTHER }

    struct acp_set_mode {
        char* session_id;
        char* mode_id;
    }

    struct acp_mode {
        const(char)* id;
        const(char)* name;
        const(char)* description;
    }

    struct acp_set_config_option {
        char* session_id;
        char* config_id;
        char* value;
        int is_boolean;
        int boolean_value;
    }

    struct acp_config_value {
        const(char)* value;
        const(char)* name;
        const(char)* description;
    }

    struct acp_config_select {
        const(char)* id;
        const(char)* name;
        const(char)* category;
        const(char)* current_value;
        const(acp_config_value)* values;
        size_t count;
    }

    const(char)* acp_version();
    const(char)* acp_status_string(acp_status);
    void acp_buffer_free(acp_buffer*);
    acp_status acp_initialize_read(const(char)*, size_t, const(uint)*, size_t, acp_initialize*, acp_buffer*);
    acp_status acp_initialize_result(uint, const(char)*, const(char)*, const(char)*, const(char)*, acp_buffer*);
    acp_status acp_authenticate_read(const(char)*, size_t, char**, acp_buffer*);
    void acp_authenticate_free(char**);
    acp_status acp_session_resume_read(const(char)*, size_t, acp_session_resume*, acp_buffer*);
    acp_status acp_session_load_read(const(char)*, size_t, acp_session_resume*, acp_buffer*);
    void acp_session_resume_free(acp_session_resume*);
    acp_status acp_session_target_read(const(char)*, const(char)*, size_t, char**, acp_buffer*);
    void acp_session_target_free(char**);
    acp_status acp_directories_read(const(char)*, size_t, acp_buffer*, acp_buffer*);
    acp_status acp_session_list_read(const(char)*, size_t, acp_session_list*, acp_buffer*);
    void acp_session_list_free(acp_session_list*);
    acp_status acp_session_info_write(const(acp_session_info)*, acp_buffer*);
    acp_status acp_prompt_read(const(char)*, size_t, acp_prompt*, acp_buffer*);
    void acp_prompt_free(acp_prompt*);
    acp_status acp_cancel_read(const(char)*, size_t, acp_cancel*);
    void acp_cancel_free(acp_cancel*);
    acp_status acp_permission_request_write(const(acp_permission_request)*, acp_buffer*);
    acp_status acp_permission_outcome_read(const(char)*, size_t, acp_permission_outcome*);
    void acp_permission_outcome_free(acp_permission_outcome*);
    acp_status acp_read_text_file_request_write(const(char)*, const(char)*, const(char)*, acp_buffer*);
    acp_status acp_read_text_file_result_read(const(char)*, size_t, acp_text_file*);
    void acp_text_file_free(acp_text_file*);
    acp_status acp_write_text_file_request_write(const(char)*, const(char)*, const(char)*, const(char)*, size_t, acp_buffer*);
    acp_status acp_write_text_file_result_read(const(char)*, size_t, int*);
    acp_status acp_terminal_create_request_write(const(char)*, const(char)*, const(char)*, const(const(char)*)*, size_t,
        const(char)*, ulong, acp_buffer*);
    acp_status acp_terminal_create_result_read(const(char)*, size_t, char**);
    void acp_terminal_id_free(char*);
    acp_status acp_terminal_output_request_write(const(char)*, const(char)*, const(char)*, acp_buffer*);
    acp_status acp_terminal_wait_for_exit_request_write(const(char)*, const(char)*, const(char)*, acp_buffer*);
    acp_status acp_terminal_kill_request_write(const(char)*, const(char)*, const(char)*, acp_buffer*);
    acp_status acp_terminal_release_request_write(const(char)*, const(char)*, const(char)*, acp_buffer*);
    acp_status acp_terminal_exit_read(const(char)*, size_t, acp_terminal_exit*);
    void acp_terminal_exit_free(acp_terminal_exit*);
    acp_status acp_terminal_output_result_read(const(char)*, size_t, acp_terminal_output*);
    void acp_terminal_output_free(acp_terminal_output*);
    acp_status acp_terminal_answered_read(const(char)*, size_t, int*);
    acp_status acp_prompt_result_write(acp_stop_reason, acp_buffer*);
    acp_status acp_session_update_write(const(char)*, const(char)*, acp_buffer*);
    acp_status acp_text_chunk_write(acp_chunk_kind, const(char)*, size_t, acp_buffer*);
    acp_status acp_image_chunk_write(acp_chunk_kind, const(char)*, const(char)*, acp_buffer*);
    acp_status acp_tool_call_write(const(acp_tool_call)*, acp_buffer*);
    acp_status acp_usage_update_write(ulong, ulong, const(char)*, const(char)*, acp_buffer*);
    acp_status acp_session_info_update_write(const(char)*, const(char)*, acp_buffer*);
    acp_status acp_available_commands_update_write(const(char)*, acp_buffer*);
    acp_status acp_notice_write(const(char)*, const(char)*, const(char)*, acp_buffer*);
    acp_status acp_elicitation_create_write(const(char)*, const(char)*, const(char)*, const(char)*, size_t, int*, acp_buffer*);
    acp_status acp_elicitation_url_write(const(char)*, const(char)*, const(char)*, const(char)*, const(char)*, acp_buffer*);
    acp_status acp_elicitation_complete_write(const(char)*, acp_buffer*);
    acp_status acp_set_mode_read(const(char)*, size_t, acp_set_mode*, acp_buffer*);
    void acp_set_mode_free(acp_set_mode*);
    acp_status acp_modes_write(const(char)*, const(acp_mode)*, size_t, acp_buffer*);
    acp_status acp_set_config_option_read(const(char)*, size_t, acp_set_config_option*, acp_buffer*);
    void acp_set_config_option_free(acp_set_config_option*);
    acp_status acp_config_options_write(const(acp_config_select)*, size_t, acp_buffer*);
}
