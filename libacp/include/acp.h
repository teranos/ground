#ifndef ACP_H
#define ACP_H

// libacp: the Agent Client Protocol, agent side, in C11 with a C ABI.
// v1 at schema-v1.26.0, v2 at schema-v2.0.0-alpha.9: https://agentclientprotocol.com

#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

#define ACP_VERSION "0.1.0-dev"

#define ACP_ERROR_INVALID_PARAMS (-32602)
// A requested version none of the supported ones fits:
// "If none exists, it MUST return -32022 with requested and supported data"
#define ACP_ERROR_UNSUPPORTED_VERSION (-32022)

typedef enum acp_status {
    ACP_OK = 0,
    ACP_INVALID_ARGUMENT,
    ACP_NO_MEMORY,
    ACP_PARSE_ERROR,
    ACP_INVALID_PARAMS,
    ACP_UNSUPPORTED_VERSION
} acp_status;

// JSON libacp wrote. The caller owns it and frees it with acp_buffer_free.
typedef struct acp_buffer {
    char *data;
    size_t length;
} acp_buffer;

// What a client offers, read in the shape of the version it requested; 1 offered, 0 not.
// v2 offers only elicitation and auth.
typedef struct acp_client_capabilities {
    int fs_read_text_file;
    int fs_write_text_file;
    int terminal;
    int session_notices;
    int elicitation_form;
    int elicitation_url;
} acp_client_capabilities;

typedef struct acp_initialize {
    unsigned requested_version; // what the client asked for
    unsigned selected_version;  // the highest supported at or below it
    acp_client_capabilities capabilities;
} acp_initialize;

const char *acp_version(void);
const char *acp_status_string(acp_status status);
void acp_buffer_free(acp_buffer *buffer);

// Reads initialize's params and selects the version the connection speaks, from supported.
// On ACP_INVALID_PARAMS or ACP_UNSUPPORTED_VERSION, error_json is the JSON-RPC error to answer.
acp_status acp_initialize_read(const char *params_json, size_t length,
                               const unsigned *supported, size_t supported_count,
                               acp_initialize *out, acp_buffer *error_json);

// The initialize result in the selected version's shape.
// Capabilities and auth methods are JSON the caller writes for that version; NULL is {} and [].
acp_status acp_initialize_result(unsigned selected_version,
                                 const char *agent_name, const char *agent_version,
                                 const char *agent_capabilities_json,
                                 const char *auth_methods_json,
                                 acp_buffer *result_json);

// authenticate's request: the methodId it names, which libacp owns until acp_authenticate_free.
acp_status acp_authenticate_read(const char *params_json, size_t length, char **method_id, acp_buffer *error_json);
void acp_authenticate_free(char **method_id);

// session/resume's request: the session, and the absolute cwd it is resumed in.
// libacp owns both strings until acp_session_resume_free.
typedef struct acp_session_resume {
    char *session_id;
    char *cwd;
} acp_session_resume;

// On ACP_INVALID_PARAMS, error_json is the JSON-RPC error to answer.
acp_status acp_session_resume_read(const char *params_json, size_t length,
                                   acp_session_resume *out, acp_buffer *error_json);
void acp_session_resume_free(acp_session_resume *resume);

// The session a request names in its own sessionId, as session/delete's does; a request
// without one is refused as method's. libacp owns *session_id until acp_session_target_free.
acp_status acp_session_target_read(const char *method, const char *params_json, size_t length,
                                   char **session_id, acp_buffer *error_json);
void acp_session_target_free(char **session_id);

// The additionalDirectories a session/new or session/resume names, as the JSON array a client
// is answered with: in order, [] when none or null. Each must be an absolute path.
acp_status acp_directories_read(const char *params_json, size_t length, acp_buffer *list_json, acp_buffer *error_json);

// session/list's request: the cwd to list in, absolute, and the cursor to page from; either NULL
// when absent or null.
typedef struct acp_session_list {
    char *cwd;
    char *cursor;
} acp_session_list;

acp_status acp_session_list_read(const char *params_json, size_t length, acp_session_list *out, acp_buffer *error_json);
void acp_session_list_free(acp_session_list *list);

// A SessionInfo. additional_directories is a JSON array; it, title and updated_at are not
// written when NULL, and neither are an empty array or title.
typedef struct acp_session_info {
    const char *session_id;
    const char *cwd;
    const char *additional_directories;
    const char *title;
    const char *updated_at;
} acp_session_info;

acp_status acp_session_info_write(const acp_session_info *info, acp_buffer *out_json);

// A session/prompt block, by what it gives: text, a resource link to read, a resource
// holding text, or another kind, told by its type.
typedef enum acp_block_kind {
    ACP_BLOCK_TEXT,
    ACP_BLOCK_RESOURCE_LINK,
    ACP_BLOCK_RESOURCE,
    ACP_BLOCK_OTHER
} acp_block_kind;

typedef struct acp_prompt_block {
    acp_block_kind kind;
    char *type;     // the type the block names; NULL when it names none
    char *text;     // TEXT's text, or RESOURCE's
    char *name;     // RESOURCE_LINK's
    char *uri;      // RESOURCE_LINK's, or RESOURCE's
    int holds_blob; // OTHER: a resource holding a blob, not text
} acp_prompt_block;

// session/prompt's prompt, in order. libacp owns the blocks until acp_prompt_free.
typedef struct acp_prompt {
    acp_prompt_block *blocks;
    size_t count;
} acp_prompt;

acp_status acp_prompt_read(const char *params_json, size_t length, acp_prompt *out, acp_buffer *error_json);
void acp_prompt_free(acp_prompt *prompt);

// A cancel: session/cancel naming its session, or $/cancel_request naming a request, its
// id as JSON text. NONE for any other message; an id a cancel does not name is NULL.
typedef enum acp_cancel_kind {
    ACP_CANCEL_NONE,
    ACP_CANCEL_SESSION,
    ACP_CANCEL_REQUEST
} acp_cancel_kind;

typedef struct acp_cancel {
    acp_cancel_kind kind;
    char *session_id;
    char *request_id;
} acp_cancel;

// Reads a whole message. libacp owns the ids until acp_cancel_free.
acp_status acp_cancel_read(const char *message_json, size_t length, acp_cancel *out);
void acp_cancel_free(acp_cancel *cancel);

// session/set_mode's request: the session, and the mode it is set to.
typedef struct acp_set_mode {
    char *session_id;
    char *mode_id;
} acp_set_mode;

acp_status acp_set_mode_read(const char *params_json, size_t length, acp_set_mode *out, acp_buffer *error_json);
void acp_set_mode_free(acp_set_mode *set_mode);

// A mode a session offers; description may be NULL.
typedef struct acp_mode {
    const char *id;
    const char *name;
    const char *description;
} acp_mode;

// A SessionModeState: current_id, which is one of modes, and every mode offered.
acp_status acp_modes_write(const char *current_id, const acp_mode *modes, size_t count, acp_buffer *out_json);

// session/set_config_option's request: a value id in value, or a boolean in boolean_value
// with is_boolean set.
typedef struct acp_set_config_option {
    char *session_id;
    char *config_id;
    char *value;
    int is_boolean;
    int boolean_value;
} acp_set_config_option;

acp_status acp_set_config_option_read(const char *params_json, size_t length, acp_set_config_option *out,
    acp_buffer *error_json);
void acp_set_config_option_free(acp_set_config_option *set_option);

// A value a select offers; description may be NULL.
typedef struct acp_config_value {
    const char *value;
    const char *name;
    const char *description;
} acp_config_value;

// A select SessionConfigOption; category may be NULL, current_value is one of values.
typedef struct acp_config_select {
    const char *id;
    const char *name;
    const char *category;
    const char *current_value;
    const acp_config_value *values;
    size_t count;
} acp_config_select;

// configOptions: the selects, in the order given.
acp_status acp_config_options_write(const acp_config_select *selects, size_t count, acp_buffer *out_json);

#ifdef __cplusplus
}
#endif

#endif
