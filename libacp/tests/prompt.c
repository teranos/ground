// session/prompt's blocks, as #135 reads them: each one text, a resource link, a resource
// holding text, or another kind told by its type.
#include "acp.h"

#include <stdio.h>
#include <string.h>

static int failures;

#define CHECK(cond) do { if (!(cond)) { fprintf(stderr, "%s:%d: %s\n", __FILE__, __LINE__, #cond); failures++; } } while (0)

static acp_status read_prompt(const char *params, acp_prompt *out, acp_buffer *error) {
    memset(out, 0, sizeof *out);
    memset(error, 0, sizeof *error);
    return acp_prompt_read(params, strlen(params), out, error);
}

static int is(const char *s, const char *want) {
    return s != NULL && strcmp(s, want) == 0;
}

static void kinds(void) {
    acp_prompt in;
    acp_buffer error;
    CHECK(read_prompt("{\"sessionId\":\"code-1-1-1\",\"prompt\":["
                      "{\"type\":\"text\",\"text\":\"say \\\"hi\\\"\"},"
                      "{\"type\":\"resource_link\",\"uri\":\"file:///a\",\"name\":\"a\"},"
                      "{\"type\":\"resource\",\"resource\":{\"uri\":\"file:///a.d\",\"mimeType\":\"text/x-d\",\"text\":\"int x;\"}},"
                      "{\"type\":\"resource\",\"resource\":{\"uri\":\"file:///a.png\",\"blob\":\"AAAA\"}},"
                      "{\"type\":\"image\",\"data\":\"x\"}]}", &in, &error) == ACP_OK);
    CHECK(in.count == 5);
    if (in.count == 5) {
        CHECK(in.blocks[0].kind == ACP_BLOCK_TEXT && is(in.blocks[0].text, "say \"hi\""));
        CHECK(in.blocks[1].kind == ACP_BLOCK_RESOURCE_LINK && is(in.blocks[1].name, "a") && is(in.blocks[1].uri, "file:///a"));
        CHECK(in.blocks[2].kind == ACP_BLOCK_RESOURCE && is(in.blocks[2].uri, "file:///a.d") && is(in.blocks[2].text, "int x;"));
        CHECK(in.blocks[3].kind == ACP_BLOCK_OTHER && is(in.blocks[3].type, "resource") && in.blocks[3].holds_blob);
        CHECK(in.blocks[4].kind == ACP_BLOCK_OTHER && is(in.blocks[4].type, "image") && !in.blocks[4].holds_blob);
    }
    acp_prompt_free(&in);
    CHECK(in.blocks == NULL && in.count == 0);
}

// "required": a link's name and uri, a resource's uri, and a block's type. Missing one, it is
// another kind, told by the type it names, or none.
static void incomplete(void) {
    acp_prompt in;
    acp_buffer error;
    CHECK(read_prompt("{\"prompt\":[{\"type\":\"resource_link\",\"uri\":\"file:///a\"},"
                      "{\"type\":\"resource\",\"resource\":{\"text\":\"no uri\"}},"
                      "{\"text\":\"a\"},7]}", &in, &error) == ACP_OK);
    CHECK(in.count == 4);
    if (in.count == 4) {
        CHECK(in.blocks[0].kind == ACP_BLOCK_OTHER && is(in.blocks[0].type, "resource_link"));
        CHECK(in.blocks[1].kind == ACP_BLOCK_OTHER && is(in.blocks[1].type, "resource") && !in.blocks[1].holds_blob);
        CHECK(in.blocks[2].kind == ACP_BLOCK_OTHER && in.blocks[2].type == NULL);
        CHECK(in.blocks[3].kind == ACP_BLOCK_OTHER && in.blocks[3].type == NULL);
    }
    acp_prompt_free(&in);
    CHECK(read_prompt("{\"prompt\":[]}", &in, &error) == ACP_OK);
    CHECK(in.count == 0);
    acp_prompt_free(&in);
}

// prompt is required, and a list.
static void refused(void) {
    acp_prompt in;
    acp_buffer error;
    const char *none[] = {"{}", "{\"prompt\":\"hi\"}", "{\"_meta\":{\"prompt\":[]}}"};
    for (size_t i = 0; i < sizeof none / sizeof *none; i++) {
        CHECK(read_prompt(none[i], &in, &error) == ACP_INVALID_PARAMS);
        CHECK(is(error.data, "{\"code\":-32602,\"message\":\"session/prompt needs prompt, a list of content blocks\"}"));
        CHECK(in.blocks == NULL && in.count == 0);
        acp_buffer_free(&error);
    }
}

// A cancel, as #137 takes one: session/cancel by its session, $/cancel_request by the
// request it names, that id as JSON text. Any other message is no cancel.
static acp_status cancel(const char *message, acp_cancel *out) {
    memset(out, 0, sizeof *out);
    return acp_cancel_read(message, strlen(message), out);
}

static void cancels(void) {
    acp_cancel c;
    CHECK(cancel("{\"jsonrpc\":\"2.0\",\"method\":\"session/cancel\",\"params\":{\"sessionId\":\"code-1-1-1\"}}", &c) == ACP_OK);
    CHECK(c.kind == ACP_CANCEL_SESSION && is(c.session_id, "code-1-1-1") && c.request_id == NULL);
    acp_cancel_free(&c);
    CHECK(c.session_id == NULL);
    CHECK(cancel("{\"jsonrpc\":\"2.0\",\"method\":\"session/cancel\",\"params\":{\"_meta\":{\"sessionId\":\"code-1-1-1\"}}}", &c) == ACP_OK);
    CHECK(c.kind == ACP_CANCEL_SESSION && c.session_id == NULL);
    acp_cancel_free(&c);
    CHECK(cancel("{\"jsonrpc\":\"2.0\",\"method\":\"$/cancel_request\",\"params\":{\"requestId\":4}}", &c) == ACP_OK);
    CHECK(c.kind == ACP_CANCEL_REQUEST && is(c.request_id, "4"));
    acp_cancel_free(&c);
    CHECK(cancel("{\"jsonrpc\":\"2.0\",\"method\":\"$/cancel_request\",\"params\":{\"requestId\":\"p/1\"}}", &c) == ACP_OK);
    CHECK(c.kind == ACP_CANCEL_REQUEST && is(c.request_id, "\"p/1\""));
    acp_cancel_free(&c);
    CHECK(cancel("{\"jsonrpc\":\"2.0\",\"method\":\"$/cancel_request\",\"params\":{}}", &c) == ACP_OK);
    CHECK(c.kind == ACP_CANCEL_REQUEST && c.request_id == NULL);
    acp_cancel_free(&c);
    const char *others[] = {"{\"jsonrpc\":\"2.0\",\"id\":3,\"method\":\"session/list\",\"params\":{}}", "not json", "[]"};
    for (size_t i = 0; i < sizeof others / sizeof *others; i++) {
        CHECK(cancel(others[i], &c) == ACP_OK);
        CHECK(c.kind == ACP_CANCEL_NONE && c.session_id == NULL && c.request_id == NULL);
    }
    CHECK(acp_cancel_read(NULL, 0, &c) == ACP_INVALID_ARGUMENT);
}

int main(void) {
    kinds();
    cancels();
    incomplete();
    refused();
    if (failures) {
        fprintf(stderr, "prompt: %d failed\n", failures);
        return 1;
    }
    printf("prompt: session/prompt's blocks, each kind, their refusals, and cancels passed\n");
    return 0;
}
