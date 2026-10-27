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

    const(char)* acp_version();
    const(char)* acp_status_string(acp_status);
    void acp_buffer_free(acp_buffer*);
    acp_status acp_initialize_read(const(char)*, size_t, const(uint)*, size_t, acp_initialize*, acp_buffer*);
    acp_status acp_initialize_result(uint, const(char)*, const(char)*, const(char)*, const(char)*, acp_buffer*);
    acp_status acp_session_resume_read(const(char)*, size_t, acp_session_resume*, acp_buffer*);
    void acp_session_resume_free(acp_session_resume*);
}
