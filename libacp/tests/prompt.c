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

int main(void) {
    kinds();
    incomplete();
    refused();
    if (failures) {
        fprintf(stderr, "prompt: %d failed\n", failures);
        return 1;
    }
    printf("prompt: session/prompt's blocks, each kind, and their refusals passed\n");
    return 0;
}
