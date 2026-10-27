// fs/read_text_file, as #156 asks it of the client: the request, and the text it answers with.
#include "acp.h"

#include <stdio.h>
#include <string.h>

static int failures;

#define CHECK(cond) do { if (!(cond)) { fprintf(stderr, "%s:%d: %s\n", __FILE__, __LINE__, #cond); failures++; } } while (0)

static int says(const acp_buffer *b, const char *want) {
    return b->data != NULL && strcmp(b->data, want) == 0;
}

// The whole request: its id, the session, and the absolute path, written as it is.
static void request(void) {
    acp_buffer out = {0};
    CHECK(acp_read_text_file_request_write("\"read-1\"", "code-1-1-1", "/tmp/a b/c\"d", &out) == ACP_OK);
    CHECK(says(&out, "{\"jsonrpc\":\"2.0\",\"id\":\"read-1\",\"method\":\"fs/read_text_file\",\"params\":"
                     "{\"sessionId\":\"code-1-1-1\",\"path\":\"/tmp/a b/c\\\"d\"}}"));
    acp_buffer_free(&out);
    CHECK(acp_read_text_file_request_write("read-1", "code-1-1-1", "/tmp/a", &out) == ACP_INVALID_ARGUMENT);
    CHECK(acp_read_text_file_request_write("\"read-1\"", "code-1-1-1", NULL, &out) == ACP_INVALID_ARGUMENT);
}

static acp_status answer(const char *message, acp_text_file *out) {
    memset(out, 0, sizeof *out);
    return acp_read_text_file_result_read(message, strlen(message), out);
}

// result.content and its every byte, a NUL among them; any other answer is no text.
static void answers(void) {
    acp_text_file file;
    CHECK(answer("{\"jsonrpc\":\"2.0\",\"id\":\"read-1\",\"result\":{\"content\":\"line one\\nline two\"}}", &file) == ACP_OK);
    CHECK(file.content && file.length == 17 && memcmp(file.content, "line one\nline two", 17) == 0);
    acp_text_file_free(&file);
    CHECK(file.content == NULL && file.length == 0);
    CHECK(answer("{\"jsonrpc\":\"2.0\",\"id\":\"read-1\",\"result\":{\"content\":\"a\\u0000b\"}}", &file) == ACP_OK);
    CHECK(file.content && file.length == 3 && memcmp(file.content, "a\0b", 3) == 0);
    acp_text_file_free(&file);
    const char *none[] = {
        "{\"jsonrpc\":\"2.0\",\"id\":\"read-1\",\"error\":{\"code\":-32002,\"message\":\"no such file\"}}",
        "{\"jsonrpc\":\"2.0\",\"id\":\"read-1\",\"result\":{\"content\":7}}",
        "{\"jsonrpc\":\"2.0\",\"id\":\"read-1\",\"result\":{}}",
        "not json",
    };
    for (size_t i = 0; i < sizeof none / sizeof *none; i++) {
        CHECK(answer(none[i], &file) == ACP_OK);
        CHECK(file.content == NULL && file.length == 0);
    }
}

int main(void) {
    request();
    answers();
    if (failures) {
        fprintf(stderr, "fs: %d failed\n", failures);
        return 1;
    }
    printf("fs: fs/read_text_file's request and the text it answers with passed\n");
    return 0;
}
