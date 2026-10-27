module libacp;

// The C ABI declared in libacp/include/acp.h. No druntime and no GC ownership.
// acp_buffer.data is freed by acp_buffer_free.

enum ACP_VERSION = "0.1.0-dev";

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
    }

    struct acp_initialize {
        uint requested_version;
        uint selected_version;
        acp_client_capabilities capabilities;
    }

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
        ACP_BLOCK_TEXT, ACP_BLOCK_RESOURCE_LINK, ACP_BLOCK_RESOURCE, ACP_BLOCK_OTHER
    }

    struct acp_prompt_block {
        acp_block_kind kind;
        char* type;
        char* text;
        char* name;
        char* uri;
        int holds_blob;
    }

    struct acp_prompt {
        acp_prompt_block* blocks;
        size_t count;
    }

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
    void acp_session_resume_free(acp_session_resume*);
    acp_status acp_session_target_read(const(char)*, const(char)*, size_t, char**, acp_buffer*);
    void acp_session_target_free(char**);
    acp_status acp_directories_read(const(char)*, size_t, acp_buffer*, acp_buffer*);
    acp_status acp_session_list_read(const(char)*, size_t, acp_session_list*, acp_buffer*);
    void acp_session_list_free(acp_session_list*);
    acp_status acp_session_info_write(const(acp_session_info)*, acp_buffer*);
    acp_status acp_prompt_read(const(char)*, size_t, acp_prompt*, acp_buffer*);
    void acp_prompt_free(acp_prompt*);
    acp_status acp_set_mode_read(const(char)*, size_t, acp_set_mode*, acp_buffer*);
    void acp_set_mode_free(acp_set_mode*);
    acp_status acp_modes_write(const(char)*, const(acp_mode)*, size_t, acp_buffer*);
    acp_status acp_set_config_option_read(const(char)*, size_t, acp_set_config_option*, acp_buffer*);
    void acp_set_config_option_free(acp_set_config_option*);
    acp_status acp_config_options_write(const(acp_config_select)*, size_t, acp_buffer*);
}
