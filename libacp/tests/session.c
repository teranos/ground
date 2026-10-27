// session/resume: the session and the place it is resumed in, as #118 reads them.
#include "acp.h"

#include <stdio.h>
#include <string.h>

static int failures;

#define CHECK(cond) do { if (!(cond)) { fprintf(stderr, "%s:%d: %s\n", __FILE__, __LINE__, #cond); failures++; } } while (0)

static acp_status resume(const char *params, acp_session_resume *out, acp_buffer *error) {
    memset(out, 0, sizeof *out);
    memset(error, 0, sizeof *error);
    return acp_session_resume_read(params, strlen(params), out, error);
}

static int says(const acp_buffer *error, const char *want) {
    return error->data != NULL && strcmp(error->data, want) == 0;
}

static void reads_the_place(void) {
    acp_session_resume in;
    acp_buffer error;
    CHECK(resume("{\"sessionId\":\"code-1-1-1\",\"cwd\":\"/work\",\"mcpServers\":[]}", &in, &error) == ACP_OK);
    CHECK(in.session_id != NULL && strcmp(in.session_id, "code-1-1-1") == 0);
    CHECK(in.cwd != NULL && strcmp(in.cwd, "/work") == 0);
    CHECK(error.data == NULL);
    acp_session_resume_free(&in);
    CHECK(in.session_id == NULL && in.cwd == NULL);
}

// Both are required, and the cwd is an absolute path.
static void refused(void) {
    acp_session_resume in;
    acp_buffer error;
    CHECK(resume("{\"cwd\":\"/work\"}", &in, &error) == ACP_INVALID_PARAMS);
    CHECK(says(&error, "{\"code\":-32602,\"message\":\"session/resume needs sessionId\"}"));
    acp_buffer_free(&error);
    CHECK(resume("{\"sessionId\":\"code-1-1-1\"}", &in, &error) == ACP_INVALID_PARAMS);
    CHECK(says(&error, "{\"code\":-32602,\"message\":\"session/resume needs cwd\"}"));
    acp_buffer_free(&error);
    CHECK(resume("{\"sessionId\":\"code-1-1-1\",\"cwd\":\"work\"}", &in, &error) == ACP_INVALID_PARAMS);
    CHECK(says(&error, "{\"code\":-32602,\"message\":\"cwd must be an absolute path: work\"}"));
    acp_buffer_free(&error);
    CHECK(resume("{\"sessionId\":7,\"cwd\":\"/work\"}", &in, &error) == ACP_INVALID_PARAMS);
    CHECK(says(&error, "{\"code\":-32602,\"message\":\"session/resume needs sessionId\"}"));
    acp_buffer_free(&error);
    CHECK(resume("[]", &in, &error) == ACP_INVALID_PARAMS);
    acp_buffer_free(&error);
    CHECK(in.session_id == NULL && in.cwd == NULL);
}

// A request that names a session and nothing else it needs, as session/delete's (#120).
static void names_a_session(void) {
    char *sid = NULL;
    acp_buffer error = {0};
    const char *ok = "{\"sessionId\":\"code-1-1-1\"}";
    CHECK(acp_session_target_read("session/delete", ok, strlen(ok), &sid, &error) == ACP_OK);
    CHECK(sid != NULL && strcmp(sid, "code-1-1-1") == 0);
    CHECK(error.data == NULL);
    acp_session_target_free(&sid);
    CHECK(sid == NULL);
    const char *none = "{\"_meta\":{\"sessionId\":\"code-1-1-1\"}}";
    CHECK(acp_session_target_read("session/delete", none, strlen(none), &sid, &error) == ACP_INVALID_PARAMS);
    CHECK(says(&error, "{\"code\":-32602,\"message\":\"session/delete needs sessionId\"}"));
    CHECK(sid == NULL);
    acp_buffer_free(&error);
    CHECK(acp_session_target_read(NULL, ok, strlen(ok), &sid, &error) == ACP_INVALID_ARGUMENT);
}

static acp_status dirs(const char *params, acp_buffer *list, acp_buffer *error) {
    memset(list, 0, sizeof *list);
    memset(error, 0, sizeof *error);
    return acp_directories_read(params, strlen(params), list, error);
}

// additionalDirectories, as #123 reads them: absolute paths, in order, decoded and answered back.
static void additional_directories(void) {
    acp_buffer list, error;
    CHECK(dirs("{\"cwd\":\"/w\",\"additionalDirectories\":[\"/lib/caf\\u00e9\",\"/lib/b\"]}", &list, &error) == ACP_OK);
    CHECK(says(&list, "[\"/lib/caf\xc3\xa9\",\"/lib/b\"]"));
    acp_buffer_free(&list);
    // None named, or null, is none.
    CHECK(dirs("{\"cwd\":\"/w\"}", &list, &error) == ACP_OK && says(&list, "[]"));
    acp_buffer_free(&list);
    CHECK(dirs("{\"additionalDirectories\":null}", &list, &error) == ACP_OK && says(&list, "[]"));
    acp_buffer_free(&list);
    // Only the params' own: a list nested in another field is not theirs.
    CHECK(dirs("{\"_meta\":{\"additionalDirectories\":[\"rel\"]}}", &list, &error) == ACP_OK && says(&list, "[]"));
    acp_buffer_free(&list);
    CHECK(dirs("{\"additionalDirectories\":[\"/lib\",\"rel\"]}", &list, &error) == ACP_INVALID_PARAMS);
    CHECK(says(&error, "{\"code\":-32602,\"message\":\"additionalDirectories must be absolute paths: rel\"}"));
    CHECK(list.data == NULL);
    acp_buffer_free(&error);
    CHECK(dirs("{\"additionalDirectories\":\"/lib\"}", &list, &error) == ACP_INVALID_PARAMS);
    CHECK(says(&error, "{\"code\":-32602,\"message\":\"additionalDirectories must be a list of paths\"}"));
    acp_buffer_free(&error);
    CHECK(dirs("{\"additionalDirectories\":[\"/lib\",7]}", &list, &error) == ACP_INVALID_PARAMS);
    CHECK(says(&error, "{\"code\":-32602,\"message\":\"additionalDirectories must be a list of paths\"}"));
    acp_buffer_free(&error);
    CHECK(dirs("{\"additionalDirectories\":[\"\"]}", &list, &error) == ACP_INVALID_PARAMS);
    CHECK(says(&error, "{\"code\":-32602,\"message\":\"additionalDirectories must be absolute paths: \"}"));
    acp_buffer_free(&error);
}

int main(void) {
    reads_the_place();
    refused();
    names_a_session();
    additional_directories();
    if (failures) {
        fprintf(stderr, "session: %d failed\n", failures);
        return 1;
    }
    printf("session: session/resume's session and cwd, and its refusals passed\n");
    return 0;
}
