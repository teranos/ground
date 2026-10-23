module parity_test;

import parity;

private bool has(K)(K keys, string key) { return listHas(keys.slice(), key); }

// FIPS 180-2 appendix B.1 and B.2: the pin is only as good as the hash.
static assert(sha256Hex("abc") == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad");
static assert(sha256Hex("abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq")
    == "248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1");
static assert(sha256Hex("") == "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855");

// The pins are read out of flake.nix, the one place they are written.
static assert(pins.length == 4);
static assert(pins[0].agent == "claude" && pins[0].release == "2.1.303");
static assert(pins[1].agent == "claude" && pins[1].release == "2.1.304");
static assert(pins[2].agent == "codex" && pins[2].release == "0.163.0");
// ACP's pin is its release's schema.json, the same file on every platform.
static assert(pins[3].agent == "acp" && pins[3].release == "1.26.0");
static assert(pins[3].sha256 == "4bcd1d2051ff7ed379bd9b234fb9b09c5ab9245478698e9fab805bd9b52a33a6");
version (OSX) version (AArch64) {
    static assert(pins[1].sha256 == "b9ac5374839f14abf3f1f45610637c332b5daee5ce0d1634726cef87aab78e6a");
    // codex's pin is the binary the tarball unpacks to, not the tarball.
    static assert(pins[2].sha256 == "8813367285524ac798dd96d1b071aea30d58708c7226fd236cd275cf1cfdee31");
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
static assert(sideFor("acp", "session/load").reads.slice() == "");
static assert(sideFor("acp", "session/load").writes.slice() == "");
// A block is the whole branch, past the errors it returns early on.
static assert(has(sideFor("acp", "session/new").reads, "cwd"));
static assert(has(sideFor("acp", "session/new").reads, "mcpServers"));
static assert(has(sideFor("acp", "session/new").writes, "sessionId"));
static assert(!has(sideFor("acp", "initialize").writes, "sessionId"));
static assert(has(sideFor("acp", "initialize").writes, "agentCapabilities"));
static assert(has(sideFor("acp", "session/close").reads, "sessionId"));
static assert(has(sideFor("acp", "session/list").reads, "cwd"));
static assert(has(sideFor("acp", "session/list").reads, "cursor"));
static assert(has(sideFor("acp", "session/list").writes, "sessions"));
// initialize writes protocolVersion and agentInfo, and reads nothing: there is
// one version to answer whatever the client asked for.
static assert(has(sideFor("acp", "initialize").writes, "protocolVersion"));
static assert(has(sideFor("acp", "initialize").writes, "agentInfo"));
static assert(sideFor("acp", "initialize").reads.slice() == "");

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
