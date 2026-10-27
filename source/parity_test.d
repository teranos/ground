module parity_test;

import parity;

private bool has(K)(K keys, string key) { return listHas(keys.slice(), key); }

// FIPS 180-2 appendix B.1 and B.2: the pin is only as good as the hash.
static assert(sha256Hex("abc") == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad");
static assert(sha256Hex("abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq")
    == "248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1");
static assert(sha256Hex("") == "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855");

// The pins are read out of flake.nix, the one place they are written.
static assert(pins[0].agent == "claude" && pins[0].release == "2.1.303");
static assert(pins[1].agent == "claude" && pins[1].release == "2.1.304");
static assert(pins[2].agent == "codex" && pins[2].release == "0.163.0");
static assert(pins[3].agent == "agy" && pins[3].release == "1.4.4");
// ACP's pin is its release's schema.json, the same file on every platform.
static assert(pins[4].agent == "acp" && pins[4].release == "1.26.0");
static assert(pins[4].sha256 == "4bcd1d2051ff7ed379bd9b234fb9b09c5ab9245478698e9fab805bd9b52a33a6");
version (OSX) {
    version (AArch64) {
        static assert(pins[1].sha256 == "b9ac5374839f14abf3f1f45610637c332b5daee5ce0d1634726cef87aab78e6a");
        // codex's pin is the binary the tarball unpacks to, not the tarball.
        static assert(pins[2].sha256 == "8813367285524ac798dd96d1b071aea30d58708c7226fd236cd275cf1cfdee31");
        // agy's pin is the antigravity binary its tarball unpacks to.
        static assert(pins[3].sha256 == "9abb478686dc08d48699ba1604c14d15819ef6a2542d5d32173acbd5f02d712d");
    } else {
        static assert(pins[1].sha256 == "f2ae409b46b1bdc1dec7afa12c6a094ff64e7d4ca272ca09f69dd0080c846703");
        static assert(pins[2].sha256 == "73697f229103f463acaafd8659976caaa4892ec11e2c246c7fa97f93d523f90e");
        static assert(pins[3].sha256 == "f6b17956d07e7021841a66e63cc9949bdddff36049c1dbba27e05c4d203b4253");
    }
}

// A pin's block closes where its braces do. Ended at the first `};`, the codex
// pin stopped after its first platform, and every other platform lost it.
private enum laterTarget = `codex "9.9.9" {
            some-other-target = {
              tarball = "1111111111111111111111111111111111111111111111111111111111111111";
              binary = "2222222222222222222222222222222222222222222222222222222222222222";
            };
            ` ~ codexTarget ~ ` = {
              tarball = "3333333333333333333333333333333333333333333333333333333333333333";
              binary = "4444444444444444444444444444444444444444444444444444444444444444";
            };
          };`;
static assert(readPins(laterTarget).count == 1);
static assert(readPins(laterTarget).items[0].sha256 == "4444444444444444444444444444444444444444444444444444444444444444");

// codex names its schemas in kebab case; ground's events are the agents' names.
static assert(pascalOf("post-tool-use").slice() == "PostToolUse");
static assert(pascalOf("stop").slice() == "Stop");

// A codex schema document, as the binary carries it.
private enum codexSample = `{
  "$schema": "http://json-schema.org/draft-07/schema#",
  "additionalProperties": false,
  "definitions": {
    "BlockDecisionWire": {
      "enum": [
        "block"
      ],
      "type": "string"
    },
    "PostToolUseHookSpecificOutputWire": {
      "additionalProperties": false,
      "properties": {
        "additionalContext": {
          "default": null,
          "type": "string"
        },
        "hookEventName": {
          "const": "PostToolUse",
          "type": "string"
        }
      },
      "required": [
        "hookEventName"
      ],
      "type": "object"
    }
  },
  "properties": {
    "continue": {
      "default": true,
      "type": "boolean"
    },
    "hookSpecificOutput": {
      "allOf": [
        {
          "$ref": "#/definitions/PostToolUseHookSpecificOutputWire"
        }
      ],
      "default": null
    },
    "reason": {
      "default": null,
      "type": "string"
    }
  },
  "title": "post-tool-use.command.output",
  "type": "object"
}`;

static assert(codexKeys(codexSample, "post-tool-use.command.output").slice()
    == "continue,hookSpecificOutput,reason,additionalContext,hookEventName");

// A claude zod object, as the binary carries it: describe strings hold colons
// and braces, and a nested object's keys are not the event's.
private enum claudeSample = `I=f(()=>u({session_id:o(),transcript_path:o(),cwd:o(),agent_id:o().optional().describe("a: {b}"),effort:u({level:N(["low"])}).optional()})),`
    ~ `LK=f(()=>I().and(u({hook_event_name:T("PostToolUse"),tool_name:o(),tool_input:oe(),duration_ms:E().optional().describe("ms (no hooks)")}))),`
    ~ `B0=f(()=>u({continue:O().optional(),suppressOutput:O().optional(),reason:o().optional(),hookSpecificOutput:Ue([y0()]).optional()})),`
    ~ `I0=f(()=>u({hookEventName:T("PostToolUse"),additionalContext:o().optional()}))`;

// The minifier names zod's helpers anew in each build: 2.1.303's are not 2.1.304's.
private enum claudeRenamed = `Q=f(()=>z({session_id:s(),transcript_path:s(),cwd:s(),agent_id:s().optional().describe("a: {b}"),effort:z({level:K(["low"])}).optional()})),`
    ~ `LK=f(()=>Q().and(z({hook_event_name:L("PostToolUse"),tool_name:s(),tool_input:w(),duration_ms:M().optional().describe("ms (no hooks)")}))),`
    ~ `B0=f(()=>z({continue:B().optional(),suppressOutput:B().optional(),reason:s().optional(),hookSpecificOutput:V([y0()]).optional()})),`
    ~ `I0=f(()=>z({hookEventName:L("PostToolUse"),additionalContext:s().optional()}))`;

static assert(claudeInputKeys(claudeRenamed, "PostToolUse").slice()
    == "session_id,transcript_path,cwd,agent_id,effort,hook_event_name,tool_name,tool_input,duration_ms");
static assert(claudeOutputKeys(claudeRenamed, "PostToolUse").slice()
    == "continue,suppressOutput,reason,hookSpecificOutput,hookEventName,additionalContext");

static assert(claudeInputKeys(claudeSample, "PostToolUse").slice()
    == "session_id,transcript_path,cwd,agent_id,effort,hook_event_name,tool_name,tool_input,duration_ms");
static assert(claudeOutputKeys(claudeSample, "PostToolUse").slice()
    == "continue,suppressOutput,reason,hookSpecificOutput,hookEventName,additionalContext");

// agy's hooks.proto descriptor, as agy 1.4.4's darwin-arm64 binary carries it:
// the package, then each message as a length-delimited field of the file.
private enum agySample = "\x12\x0cexa.hooks_pb"
    ~ "\"e\x0a\x0fPreToolHookArgs\x127\x0a\x09tool_call\x18\x01 \x01(\x0b2\x1a.exa.hooks_pb.HookToolCallR\x08toolCall\x12\x19\x0a\x08step_idx\x18\x02 \x01(\x05R\x07stepIdx"
    ~ "\"\xab\x02\x0a\x11PreToolHookResult\x12#\x0a\x08decision\x18\x04 \x01(\x09B\x07\xa0\xa0\xf0\x98\x01\xf0\x15R\x08decision\x12\x1f\x0a\x06reason\x18\x05 \x01(\x09B\x07\xa0\xa0\xf0\x98\x01\xec\x0eR\x06reason\x12>\x0a\x09overwrite\x18\x03 \x01(\x0b2\x17.google.protobuf.StructB\x07\xa0\xa0\xf0\x98\x01\xec\x0eR\x09overwrite\x12:\x0a\x14permission_overrides\x18\x06 \x03(\x09B\x07\xa0\xa0\xf0\x98\x01\xec\x0eR\x13permissionOverrides\x12(\x0a\x0aallow_tool\x18\x01 \x01(\x08B\x09\xa0\xa0\xf0\x98\x01\xf0\x15\x18\x01R\x09allowTool\x12*\x0a\x0bdeny_reason\x18\x02 \x01(\x09B\x09\xa0\xa0\xf0\x98\x01\xec\x0e\x18\x01R\x0adenyReason";

private bool agyHas()(string text, string name) {
    Keys k;
    auto a = agyAnchor(text);
    return a >= 0 && agyMessage(text, cast(size_t) a, name, k);
}

static assert(agyKeys(agySample, "PreToolHookArgs").slice() == "toolCall,stepIdx");
// Past 127 bytes a message's length takes two; a field's options hold bytes of their own.
static assert(agyKeys(agySample, "PreToolHookResult").slice()
    == "decision,reason,overwrite,permissionOverrides,allowTool,denyReason");
// A name another message refers to by type is not that message.
static assert(!agyHas(agySample, "HookToolCall"));
static assert(!agyHas(agySample, "StopHookResult"));

static assert(jsonKeys(`{"decision":"ask","reason":"a {b}: c","x":{"y":1}}`).slice() == "decision,reason,x");
static assert(jsonKeys(`{}`).slice() == "");

// agy's side is agy.d's: what it reads of every event, and what it answers each.
static assert(sideOf("agy", "PreToolUse").reads.slice() == "conversationId,workspacePaths");
static assert(sideOf("agy", "PreToolUse").writes.slice() == "decision");
static assert(sideOf("agy", "Stop").writes.slice() == "");
// codex runs the handlers Claude Code does.
static assert(sideOf("codex", "PostToolUse").writes.slice() == sideOf("claude", "PostToolUse").writes.slice());

// "Pin the latest stable deepseek harness In parity"
// dsh has no hook contract of its own: it runs Claude Code's and Codex's hooks,
// each a plugin of its own. Its pins are those bridges' bundles, the same on
// every platform, each beside the hook-protocol bundle that reads a hook's reply.
static assert(pins[10].agent == "dsh-claude" && pins[10].release == "0.2.1-rc.5");
static assert(pins[10].sha256 == "c4f3f5d92c82e790593d977d95eef0afa4ffad07bb9b9d1609ae613fe6a76283");
static assert(pins[10].protocol == "1edd96fed80f2fb02840da4ae1af3c81a78988f018e057cc8f8eb70dfc23c132");
static assert(pins[11].agent == "dsh-codex" && pins[11].release == "0.2.1-rc.5");
static assert(pins[11].sha256 == "4f245084fa3a90f6740446e124962a2037c8a8be5f1daf3085ee1c1004a6fa86");
static assert(pins[11].protocol == "1edd96fed80f2fb02840da4ae1af3c81a78988f018e057cc8f8eb70dfc23c132");

// A bridge's bundle, as dsh-hooks-claude-code 0.2.1-rc.5 and dsh-hooks-codex
// carry it: every hook runs through runPoint, whose payload the run widens.
private enum dshSample = `
			const { output, durationMs } = await runHook(ctx.shell, hook, {
				payload: {
					...payload,
					cwd: workdir ?? process.cwd()
				},
				timeoutMs: 600000
			});
		const merged = await runPoint("UserPromptSubmit", "", {
			...turnBase(ctx, agent, "UserPromptSubmit", model),
			prompt: blocksToText(messages.flatMap((message) => message.content))
		}, {
			agent,
			signal
		});
		const merged = await runPoint("PreToolUse", exec.name, preToolPayload(exec), {
			...exec.agent ? { agent: exec.agent } : {},
			signal: exec.signal
		});
		detached.track(runPoint("SubagentStart", SUBAGENT_TYPE, subagentPayload("SubagentStart", info, child), {
			signal: detached.signal
		}));
		detached.track(runPoint("SubagentStop", SUBAGENT_TYPE, subagentPayload("SubagentStop", info, child), {
			signal: detached.signal
		}));
function base(agent, event) {
	return {
		session_id: agent?.session.header.id ?? "",
		transcript_path: "",
		hook_event_name: event
	};
}
function turnBase(ctx, agent, event, model) {
	return {
		...base(agent, event),
		turn_id: String(lastTurn(ctx, agent))
	};
}
function preToolPayload(exec) {
	return {
		...base(exec.agent, "PreToolUse"),
		tool_name: exec.name,
		tool_input: { command: commandOf(exec.arguments) },
		tool_use_id: exec.callId
	};
}
function subagentPayload(event, info, child) {
	return {
		...base(child, event),
		agent_id: info.id,
		agent_type: SUBAGENT_TYPE,
		...event === "SubagentStop" ? { stop_hook_active: false } : {}
	};
}
`;
static assert(dshEvents(dshSample).slice() == "UserPromptSubmit,PreToolUse,SubagentStart,SubagentStop");
static assert(dshInputKeys(dshSample, "UserPromptSubmit").slice() == "cwd,session_id,transcript_path,hook_event_name,turn_id,prompt");
// A key nested in a value is the value's, not the payload's.
static assert(dshInputKeys(dshSample, "PreToolUse").slice() == "cwd,session_id,transcript_path,hook_event_name,tool_name,tool_input,tool_use_id");
// A spread that tests the event is the event's alone.
static assert(!has(dshInputKeys(dshSample, "SubagentStart"), "stop_hook_active"));
static assert(has(dshInputKeys(dshSample, "SubagentStop"), "stop_hook_active"));
static assert(dshInputKeys(dshSample, "Stop").slice() == "");

// What dsh-hook-protocol reads of a hook's reply, the same for every event.
private enum dshProtocolSample = `
function applyStructured(output, parsed, expectedEventName) {
	const cont = bool(parsed, "continue");
	if (cont !== void 0) output.continue = cont;
	const topDecision = topLevelDecisionOf(str(parsed, "decision"));
	const hso = obj(parsed.hookSpecificOutput);
	if (hso) {
		const eventName = str(hso, "hookEventName");
		if (eventName !== void 0) output.hookEventName = eventName;
		const permission = permissionDecisionOf(str(hso, "permissionDecision"));
		const updated = obj(hso.updatedInput);
		if (updated !== void 0) output.updatedInput = updated;
	}
}
function other(parsed) { return str(parsed, "notRead"); }
`;
static assert(dshOutputKeys(dshProtocolSample).slice() == "continue,decision,hookSpecificOutput,hookEventName,permissionDecision,updatedInput");

// dsh runs the hooks ground installs for Claude Code and codex, in their dialects.
static assert(sideOf("dsh-claude", "PreToolUse").reads.slice() == sideOf("claude", "PreToolUse").reads.slice());
static assert(sideOf("dsh-codex", "Stop").writes.slice() == sideOf("codex", "Stop").writes.slice());

// The ACP schema, as its release publishes it: every request, response and
// notification names its method and the side that handles it. A key nested in
// one of them is not the method's.
private enum acpSample = `{
  "$schema": "https://json-schema.org/draft/2020-12/schema",
  "$defs": {
    "ReadTextFileRequest": {
      "type": "object",
      "properties": {
        "sessionId": {
          "allOf": [
            {
              "$ref": "#/$defs/SessionId"
            }
          ]
        },
        "path": {
          "type": "string"
        }
      },
      "required": ["sessionId", "path"],
      "x-side": "client",
      "x-method": "fs/read_text_file"
    },
    "PromptResponse": {
      "type": "object",
      "properties": {
        "stopReason": {
          "allOf": [
            {
              "$ref": "#/$defs/StopReason"
            }
          ]
        },
        "_meta": {
          "type": ["object", "null"]
        }
      },
      "required": ["stopReason"],
      "x-side": "agent",
      "x-method": "session/prompt"
    },
    "ReadTextFileResponse": {
      "type": "object",
      "properties": {
        "content": {
          "type": "string"
        }
      },
      "x-side": "client",
      "x-method": "fs/read_text_file"
    },
    "SessionNotification": {
      "type": "object",
      "properties": {
        "sessionId": {
          "type": "string"
        },
        "update": {
          "type": "object",
          "properties": {
            "sessionUpdate": {
              "type": "string"
            }
          }
        }
      },
      "x-side": "client",
      "x-method": "session/update"
    },
    "PromptRequest": {
      "type": "object",
      "properties": {
        "sessionId": {
          "type": "string"
        },
        "prompt": {
          "type": "array"
        },
        "_meta": {
          "type": ["object", "null"]
        }
      },
      "x-side": "agent",
      "x-method": "session/prompt"
    },
    "CancelRequestNotification": {
      "type": "object",
      "properties": {
        "requestId": {
          "type": "string"
        }
      },
      "x-side": "protocol",
      "x-method": "$/cancel_request"
    }
  }
}`;

// In and out are ground code's side, as they are ground's for a hook: in is
// what it reads, out is what it writes. A method the agent handles reads the
// request and writes the response; one the client handles is the other way
// round, and a notification has only the side that sends it.
static assert(acpKeys(acpSample, "session/prompt").input.slice() == "sessionId,prompt,_meta");
static assert(acpKeys(acpSample, "session/prompt").output.slice() == "stopReason,_meta");
static assert(acpKeys(acpSample, "fs/read_text_file").input.slice() == "content");
static assert(acpKeys(acpSample, "fs/read_text_file").output.slice() == "sessionId,path");
static assert(acpKeys(acpSample, "session/update").input.slice() == "");
static assert(acpKeys(acpSample, "session/update").output.slice() == "sessionId,update");
// Either peer may cancel a request, so ground code both reads and writes it.
static assert(acpKeys(acpSample, "$/cancel_request").input.slice() == "requestId");
static assert(acpKeys(acpSample, "$/cancel_request").output.slice() == "requestId");
static assert(acpKeys(acpSample, "session/missing").input.slice() == "");

// Ground code's side is read out of code/acp.d, one method's block at a time. The
// hook side would have claimed session/new's cwd: main.d reads a cwd from
// every hook payload, and that is not ground code handling session/new.
static assert(has(sideFor("claude", "session/new").reads, "cwd"));
static assert(sideFor("acp", "logout").reads.slice() == "");
static assert(sideFor("acp", "logout").writes.slice() == "");
static assert(has(sideFor("acp", "session/load").reads, "sessionId"));
static assert(has(sideFor("acp", "session/load").reads, "mcpServers"));
static assert(has(sideFor("acp", "session/load").writes, "configOptions"));
// A block is the whole branch, past the errors it returns early on.
static assert(has(sideFor("acp", "session/new").reads, "cwd"));
static assert(has(sideFor("acp", "session/new").reads, "mcpServers"));
static assert(has(sideFor("acp", "session/new").writes, "sessionId"));
static assert(!has(sideFor("acp", "initialize").writes, "sessionId"));
static assert(has(sideFor("acp", "initialize").writes, "authMethods"));
static assert(has(sideFor("acp", "authenticate").reads, "methodId"));
// A key read through a helper is the helper's, marked as reading it, as parse.d's
// extractors are: session/prompt's prompt is read by promptText.
static assert(has(sideFor("acp", "session/prompt").reads, "prompt"));
// A method ground code sends has no branch: its side is the function that
// writes it, and that function's message is its out.
static assert(has(sideFor("acp", "session/update").writes, "sessionId"));
static assert(has(sideFor("acp", "session/update").writes, "update"));
static assert(!has(sideFor("acp", "session/update").writes, "stopReason"));
static assert(sentBlock("x\nprivate bool f() {\n    a(`{\"method\":\"m\",\"k\":1}`);\n}\nvoid g() { }\n", "m")
    == "private bool f() {\n    a(`{\"method\":\"m\",\"k\":1}`);\n}");
static assert(sentBlock("void g() { }\n", "m") is null);
static assert(has(sideFor("acp", "initialize").writes, "agentCapabilities"));
static assert(has(sideFor("acp", "session/close").reads, "sessionId"));
static assert(has(sideFor("acp", "session/list").reads, "cwd"));
static assert(has(sideFor("acp", "session/list").reads, "cursor"));
static assert(has(sideFor("acp", "session/list").writes, "sessions"));
static assert(has(sideFor("acp", "session/resume").reads, "sessionId"));
static assert(has(sideFor("acp", "session/resume").reads, "cwd"));
static assert(has(sideFor("acp", "session/delete").reads, "sessionId"));
static assert(has(sideFor("acp", "session/new").writes, "modes"));
static assert(has(sideFor("acp", "session/resume").writes, "modes"));
static assert(has(sideFor("acp", "session/set_mode").reads, "modeId"));
static assert(has(sideFor("acp", "session/new").reads, "additionalDirectories"));
static assert(has(sideFor("acp", "session/resume").reads, "additionalDirectories"));
static assert(has(sideFor("acp", "session/new").writes, "configOptions"));
static assert(has(sideFor("acp", "session/resume").writes, "configOptions"));
static assert(has(sideFor("acp", "session/set_config_option").reads, "configId"));
static assert(has(sideFor("acp", "session/set_config_option").writes, "configOptions"));
// initialize is read and written by libacp, out of its C: it reads the version
// asked for and the client's capabilities in either shape, and writes the
// selected version, the agent's capabilities and its info.
static assert(has(sideFor("acp", "initialize").writes, "protocolVersion"));
static assert(has(sideFor("acp", "initialize").writes, "agentInfo"));
static assert(has(sideFor("acp", "initialize").reads, "clientCapabilities"));
static assert(has(sideFor("acp", "initialize").reads, "capabilities"));
static assert(has(sideFor("acp", "initialize").reads, "protocolVersion"));
static assert(has(sideFor("acp", "fs/read_text_file").writes, "path"));
static assert(has(sideFor("acp", "fs/read_text_file").reads, "content"));
// A turn's answer is libacp's, through putStop: still measured as session/prompt's.
static assert(has(sideFor("acp", "session/prompt").writes, "stopReason"));
// A request libacp writes for ground code is measured through the helper that
// sends it: the method's own fields, and those of the answer it reads.
static assert(has(sideFor("acp", "session/request_permission").writes, "toolCall"));
static assert(has(sideFor("acp", "session/request_permission").writes, "options"));
static assert(has(sideFor("acp", "session/request_permission").reads, "outcome"));
// A notification ground code passes on is written with its own fields, so
// they are measured: elicitation/complete's elicitationId.
static assert(has(sideFor("acp", "elicitation/complete").writes, "elicitationId"));

// "i want it"
// MCP's pins are each released schema.json at one spec commit, the version as
// the release. libmcp is the client the table measures.
static assert(pins.length == 12);
static assert(pins[5].agent == "mcp" && pins[5].release == "2024-11-05");
static assert(pins[5].sha256 == "61cea2392d4f284092d09bc84b9ac488c0d5618ac2b38a56942fc5b99fd960ce");
static assert(pins[9].agent == "mcp" && pins[9].release == "2026-07-28");
static assert(pins[9].sha256 == "ef70b61f99b6d2e5e3b46863822eab08dff6a45bedc7a08914e0e5b133f40203");

// An MCP schema: who sends a method is which union names it, its params are
// inline or a reference to their own definition, and its result is named
// after its request.
private enum mcpSample = `{
    "$schema": "https://json-schema.org/draft/2020-12/schema",
    "$defs": {
        "CallToolRequest": {
            "properties": {
                "method": {
                    "const": "tools/call",
                    "type": "string"
                },
                "params": {
                    "$ref": "#/$defs/CallToolRequestParams"
                }
            },
            "type": "object"
        },
        "CallToolRequestParams": {
            "properties": {
                "arguments": {
                    "type": "object"
                },
                "name": {
                    "type": "string"
                }
            },
            "type": "object"
        },
        "CallToolResult": {
            "properties": {
                "content": {
                    "type": "array"
                },
                "isError": {
                    "type": "boolean"
                }
            },
            "type": "object"
        },
        "ClientRequest": {
            "anyOf": [
                {
                    "$ref": "#/$defs/CallToolRequest"
                }
            ]
        },
        "CreateMessageRequest": {
            "properties": {
                "method": {
                    "const": "sampling/createMessage",
                    "type": "string"
                },
                "params": {
                    "properties": {
                        "maxTokens": {
                            "type": "integer"
                        },
                        "messages": {
                            "type": "array"
                        }
                    },
                    "type": "object"
                }
            },
            "type": "object"
        },
        "CreateMessageResult": {
            "properties": {
                "model": {
                    "type": "string"
                }
            },
            "type": "object"
        },
        "ProgressNotification": {
            "properties": {
                "method": {
                    "const": "notifications/progress",
                    "type": "string"
                },
                "params": {
                    "properties": {
                        "progress": {
                            "type": "number"
                        },
                        "progressToken": {
                            "type": "string"
                        }
                    },
                    "type": "object"
                }
            },
            "type": "object"
        },
        "ServerNotification": {
            "anyOf": [
                {
                    "$ref": "#/$defs/ProgressNotification"
                }
            ]
        },
        "ServerRequest": {
            "anyOf": [
                {
                    "$ref": "#/$defs/CreateMessageRequest"
                }
            ]
        }
    }
}`;

// In and out are libmcp's side: a request the client sends is written and its
// result read; one the server sends is read and its result written; a
// notification has only the side that sends it.
static assert(mcpKeys(mcpSample, "tools/call").output.slice() == "arguments,name");
static assert(mcpKeys(mcpSample, "tools/call").input.slice() == "content,isError");
static assert(mcpKeys(mcpSample, "sampling/createMessage").input.slice() == "maxTokens,messages");
static assert(mcpKeys(mcpSample, "sampling/createMessage").output.slice() == "model");
static assert(mcpKeys(mcpSample, "notifications/progress").input.slice() == "progress,progressToken");
static assert(mcpKeys(mcpSample, "notifications/progress").output.slice() == "");
static assert(mcpKeys(mcpSample, "tools/missing").input.slice() == "");

// libmcp's side is read out of its C: the branch that tests for a method, or
// the function that sends it, what it reads with mcp_field, mcp_has and
// json_object_object_get_ex, and what it writes with mcp_add.
static assert(has(sideFor("mcp", "notifications/progress").reads, "progressToken"));
static assert(has(sideFor("mcp", "notifications/progress").reads, "total"));
static assert(has(sideFor("mcp", "elicitation/create").reads, "mode"));
static assert(has(sideFor("mcp", "initialize").writes, "protocolVersion"));
static assert(has(sideFor("mcp", "initialize").writes, "clientInfo"));
static assert(has(sideFor("mcp", "initialize").reads, "serverInfo"));
static assert(has(sideFor("mcp", "subscriptions/listen").writes, "notifications"));
// A key passed to the call that sends the method is written by it.
static assert(has(sideFor("mcp", "tools/list").writes, "cursor"));
static assert(has(sideFor("mcp", "tools/call").writes, "name"));
// What a function the block calls writes is the block's: helper adds arguments.
static assert(has(sideFor("mcp", "tools/call").writes, "arguments"));
// A key read into a name is read wherever the name is used: isError is
// tool_error, which the tools/call branch tests.
static assert(has(sideFor("mcp", "tools/call").reads, "isError"));
// A name a method's test is kept in stands for the method: ack.
static assert(has(sideFor("mcp", "notifications/subscriptions/acknowledged").reads, "notifications"));
static assert(sideFor("mcp", "no/such/method").reads.slice() == "");
// What mcp_dispatch reads of every message before it tells one method from
// another is every method's: resultType is read from every result.
static assert(has(sideFor("mcp", "tools/list").reads, "resultType"));
// What build_message writes into every request, and mcp_request_resume into
// every continuation, is every request's.
static assert(has(sideFor("mcp", "tools/call").writes, "_meta"));
static assert(has(sideFor("mcp", "tools/call").writes, "inputResponses"));
static assert(has(sideFor("mcp", "tools/call").writes, "requestState"));

// Ground's side is read out of its own source: main.d's reads for every event,
// the handler main.d dispatches to, and the extractors that handler calls.
static assert(has(groundReads!"PostToolUse", "cwd"));
static assert(has(groundReads!"PostToolUse", "session_id"));
static assert(has(groundReads!"PostToolUse", "hook_event_name"));
static assert(has(groundReads!"PostToolUse", "tool_name"));
static assert(has(groundReads!"PostToolUse", "tool_input"));
static assert(has(groundReads!"PostToolUse", "tool_response"));
static assert(has(groundReads!"PostToolUse", "tool_use_id"));
static assert(!has(groundReads!"PostToolUse", "permission_mode"));
static assert(has(groundReads!"PreToolUse", "permission_mode"));
static assert(has(groundReads!"Stop", "stop_hook_active"));
static assert(has(groundReads!"Stop", "last_assistant_message"));
static assert(has(groundReads!"SessionStart", "source"));
static assert(!has(groundReads!"UserPromptSubmit", "source"));
// An event ground dispatches nowhere still has the reads main.d makes first.
static assert(groundReads!"Interrupt".slice() == "cwd,session_id,hook_event_name");

static assert(has(groundWrites!"PostToolUse", "hookSpecificOutput"));
static assert(has(groundWrites!"PostToolUse", "additionalContext"));
static assert(!has(groundWrites!"PostToolUse", "decision"));
static assert(has(groundWrites!"Stop", "decision"));
static assert(has(groundWrites!"Stop", "stopReason"));

// "in is 50% and out is 50%"
static assert(score(1, 2, 1, 4) == 375);        // per mille: 0.5*500 + 0.5*250
static assert(score(7, 13, 3, 10) == 419);
static assert(score(1, 2, 0, 0) == 500);        // a side the spec does not have weighs nothing
static assert(score(0, 0, 0, 0) == -1);
static assert(percentOf(625) == 63);           // rounded half up
static assert(percentOf(624) == 62);

static assert(covered("a,b,c", "b,c,d") == 2);
static assert(covered("", "b") == 0);

// "is to record how we are doing on parity over time against different specs and also have that plot as a line."
// A harness's total is the mean of its cells. A spec with neither side is no cell.
static assert(total([390, 610, -1]) == 500);
static assert(total([-1, -1]) == -1);

// "so we give each harness a line for total coverage"
// "and ACP as well separately"
enum pts = [Point("claude", "2026-10-21 20:12", 270), Point("claude", "2026-10-23 12:00", 300),
            Point("acp", "2026-10-23 12:00", 50)];
static assert(seriesTex(pts).text() ==
    "\\begin{tikzpicture}\n"
    ~ "\\begin{axis}[date coordinates in=x, xticklabel={\\day.\\month.}, ymin=0, ymax=100, "
    ~ "ylabel={\\%}, legend pos=north west, width=\\textwidth, height=60mm]\n"
    ~ "\\addplot coordinates {(2026-10-21 20:12,27) (2026-10-23 12:00,30)};\n\\addlegendentry{claude}\n"
    ~ "\\addplot coordinates {(2026-10-23 12:00,5)};\n\\addlegendentry{acp}\n"
    ~ "\\end{axis}\n\\end{tikzpicture}\n");

// No runs, no plot: the page carries nothing rather than empty axes.
static assert(seriesTex([]).text() == "");

// A run attests one row per spec, and the series reads one point per harness
// per run: the mean of that harness's specs.
unittest {
    import db : sqlite3, sqlite3_open, sqlite3_close, applySchema, SQLITE_OK;
    sqlite3* db;
    assert(sqlite3_open(":memory:", &db) == SQLITE_OK);
    assert(applySchema(db));
    assert(attestParity(db, "claude", "2.1.303", "aa", 270, "2026-10-21T20:12:00Z"));
    assert(attestParity(db, "claude", "2.1.304", "bb", 290, "2026-10-21T20:12:00Z"));
    assert(attestParity(db, "acp", "1.26.0", "cc", 50, "2026-10-21T20:12:00Z"));
    assert(attestParity(db, "claude", "2.1.304", "bb", 310, "2026-10-23T12:00:00Z"));
    auto s = readSeries(db);
    assert(s.count == 3);
    assert(s.at(0).agent == "claude" && s.at(0).when == "2026-10-21 20:12" && s.at(0).total == 280);
    assert(s.at(1).agent == "acp" && s.at(1).when == "2026-10-21 20:12" && s.at(1).total == 50);
    assert(s.at(2).agent == "claude" && s.at(2).when == "2026-10-23 12:00" && s.at(2).total == 310);
    sqlite3_close(db);
}
