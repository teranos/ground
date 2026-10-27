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

int main(void) {
    reads_the_place();
    refused();
    if (failures) {
        fprintf(stderr, "session: %d failed\n", failures);
        return 1;
    }
    printf("session: session/resume's session and cwd, and its refusals passed\n");
    return 0;
}
