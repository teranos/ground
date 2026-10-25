"""Independent oracle: run with the pinned official Python SDK, never the wire peer."""

import asyncio
import sys
from mcp.server.lowlevel import Server
from mcp.server.stdio import stdio_server
import mcp_types as t


async def tools(ctx, params):
    return t.ListToolsResult(
        tools=[
            t.Tool(
                name="sdk-echo",
                description="Official SDK fixture",
                input_schema={
                    "type": "object",
                    "properties": {"value": {"type": "string"}},
                },
            )
        ]
    )


async def call(ctx, params):
    return t.CallToolResult(
        content=[t.TextContent(type="text", text=params.arguments.get("value", ""))]
    )


server = Server("libmcp-independent-oracle", on_list_tools=tools, on_call_tool=call)


async def main():
    async with stdio_server() as (read, write):
        await server.run(read, write, server.create_initialization_options())


if __name__ == "__main__":
    if len(sys.argv) > 1:
        import uvicorn

        uvicorn.run(
            server.streamable_http_app(json_response=sys.argv[1] == "json"),
            host="127.0.0.1",
            port=int(sys.argv[2]),
            log_level="warning",
        )
    else:
        asyncio.run(main())
