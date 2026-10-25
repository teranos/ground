/* Fault injection at the parser boundary: memory failure is never malformed JSON. */
#include "internal.h"
#include <assert.h>
#include <stdlib.h>
#include <string.h>
static int fail_parser;
struct json_tokener *__real_json_tokener_new_ex(int);
struct json_tokener *__wrap_json_tokener_new_ex(int depth) {
    if (fail_parser) return NULL;
    return __real_json_tokener_new_ex(depth);
}
int main(void) {
    json *out=NULL; mcp_error e={0};
    fail_parser=1;
    assert(mcp_parse("{}",2,&out,&e)==MCP_NO_MEMORY && e.code==MCP_NO_MEMORY && !out);
    fail_parser=0;
    const char *bad[]={"{\"n\":NaN}","{\"n\":Infinity}","{'n':1}","{\"n\":01}","{\"n\":1.}","{\"n\":+1}","{} garbage","{\"x\":\"\xc0\x80\"}","{\"x\":\"\xed\xa0\x80\"}","{\"x\":\"\xf4\x90\x80\x80\"}"};
    for(size_t i=0;i<sizeof(bad)/sizeof(*bad);i++)assert(mcp_parse(bad[i],strlen(bad[i]),&out,&e)==MCP_PROTOCOL_ERROR && !out);
    assert(mcp_parse("{\"x\":\"☃\"}",strlen("{\"x\":\"☃\"}"),&out,&e)==MCP_OK);json_object_put(out);
    assert(mcp_parse("{\"x\":\"\\u0000\"}",14,&out,&e)==MCP_OK);
    assert(json_object_get_string_len(mcp_field(out,"x"))==1);json_object_put(out);
    return 0;
}
