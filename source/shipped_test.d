module shipped_test;

import shipped;

// What an SDK says each ACP method is called, read from the SDK's own source.
private enum schemaText = q"EOS
export const AGENT_METHODS = {
  initialize: "initialize",
  session_new: "session/new",
  session_cancel: "session/cancel",
} as const;

export const CLIENT_METHODS = {
  session_update: "session/update",
  terminal_create: "terminal/create",
  terminal_kill: "terminal/kill",
} as const;
EOS";

// 0.16's shape: a case per method, calling the agent's or the client's own method.
private enum dispatchText = q"EOS
      switch (method) {
        case schema.AGENT_METHODS.session_new: {
          const validatedParams = validate.zNewSessionRequest.parse(params);
          return agent.newSession(validatedParams);
        }
        case schema.AGENT_METHODS.session_cancel: {
          if (!agent.cancel) {
            throw RequestError.methodNotFound(method);
          }
          return agent.cancel(validatedParams);
        }
        case schema.CLIENT_METHODS.session_update: {
          return client.sessionUpdate(validatedParams);
        }
        case schema.CLIENT_METHODS.terminal_create: {
          return client.createTerminal?.(validatedParams);
        }
      }

export class TerminalHandle {
  async kill(): Promise<void> {
    await this.#connection.sendRequest(schema.CLIENT_METHODS.terminal_kill, {
      sessionId: this.#sessionId,
    });
  }
}
EOS";

// 2.x's shape: a table of paths, and a spec per interface name.
private enum tableText = q"EOS
export const methods = {
  agent: {
    initialize: schema.AGENT_METHODS.initialize,
    session: {
      new: schema.AGENT_METHODS.session_new,
      cancel: schema.AGENT_METHODS.session_cancel,
    },
  },
  client: {
    session: {
      update: schema.CLIENT_METHODS.session_update,
    },
  },
} as const;

const agentRequestSpecs = {
  newSession: requestSpec<schema.NewSessionRequest, schema.NewSessionResponse>(
    schema.AGENT_METHODS.session_new,
    validate.zNewSessionRequest,
  ),
};
EOS";

private SdkMap mapOf(string acp) {
    SdkMap map;
    readSchema(schemaText, map);
    readAcp(acp, map);
    return map;
}

private bool handles(ref const Found f, ref const SdkMap map, string method) {
    auto i = map.indexOf(method);
    return i >= 0 && f.handles[i];
}

private bool sends(ref const Found f, ref const SdkMap map, string method) {
    auto i = map.indexOf(method);
    return i >= 0 && f.sends[i];
}

// The methods are the SDK's strings, each on the side its table puts it.
unittest {
    auto map = mapOf(dispatchText);
    assert(map.indexOf("session/new") >= 0);
    assert(map.methods[map.indexOf("session/new")].agentHandles);
    assert(!map.methods[map.indexOf("session/update")].agentHandles);
    assert(map.indexOf("session/prompt") < 0, "a method no table names is no method");
}

// "and compare us against real shipped software instyead of comparing against a number that might not be real"
// A classic agent handles what the class it hands the SDK defines, and nothing another class defines.
unittest {
    auto map = mapOf(dispatchText);
    enum agent = q"EOS
const conn = new acp.AgentSideConnection(
  (c) => new PiAgent(c),
  stream,
);
export class PiAgent implements Agent {
  async newSession(params: NewSessionRequest) {
    await this.conn.sessionUpdate({ sessionId });
    return { sessionId };
  }
}
class Other {
  async cancel(): Promise<void> {}
}
EOS";
    Found f;
    scanAgent(agent, map, f);
    finish(f, map);
    assert(handles(f, map, "session/new"));
    assert(!handles(f, map, "session/cancel"), "a method another class defines is not the agent's");

    Found guarded;
    scanAgent("new AgentSideConnection((c) => new A(c), s);\nclass A {\n  async cancel() {\n  }\n}\n", map, guarded);
    assert(handles(guarded, map, "session/cancel"), "the SDK's guard before its call names the same method");
    assert(sends(f, map, "session/update"));
    assert(!sends(f, map, "terminal/create"));
}

// A router agent handles what it registers by the SDK's paths, and sends what it notifies.
unittest {
    auto map = mapOf(tableText);
    enum agent = q"EOS
  return router
    .onRequest(v2.methods.agent.session.new, async ({ params }) => agent.newSession(params))
    .onNotification(v2.methods.agent.session.cancel, ({ params }) => agent.cancel(params));
  // a mention in a comment of methods.agent.initialize is still a mention
  await this.ctx.notify(methods.client.session.update, notification);
EOS";
    Found f;
    scanAgent(agent, map, f);
    finish(f, map);
    assert(handles(f, map, "session/new"));
    assert(handles(f, map, "session/cancel"));
    assert(sends(f, map, "session/update"));
}

// A handle's method named as plainly as kill is the terminal's only where the agent made one.
unittest {
    auto map = mapOf(dispatchText);
    Found none;
    scanAgent("  child.kill();\n", map, none);
    finish(none, map);
    assert(!sends(none, map, "terminal/kill"), "a process killed is not a terminal killed");

    Found made;
    scanAgent("  const t = await this.client.createTerminal({ command });\n  await t.kill();\n", map, made);
    finish(made, map);
    assert(sends(made, map, "terminal/create"));
    assert(sends(made, map, "terminal/kill"));
}

// The pins read out of flake.nix: each shipped agent at a commit, and each SDK version.
unittest {
    enum flake = q"EOS
          shipped-pi-acp = shipped "pi-acp" {
            owner = "svkozak"; repo = "pi-acp";
            rev = "04d0a15d6bb42bb65cce5c9caedcdcb2cdcb6905";
            hash = "sha256-V9+WNpJQK2a/S3e5KVXfiK1bhQlXrUKIaowhOZa6BIg=";
            dir = "src"; sdk = "0.26.0";
          };
          acp-sdk-0_26_0 = acpSdk "0.26.0" {
            rev = "73bc30649b650de320340c782733bf69a545bd28";
            hash = "sha256-DlcmeqUvED2sKCCBOIjAnp8sEoIhtPHdAqoI8/fBnt0=";
          };
EOS";
    enum pins = readShipped(flake);
    static assert(pins.count == 1);
    static assert(pins.items[0].name == "pi-acp");
    static assert(pins.items[0].rev == "04d0a15d6bb42bb65cce5c9caedcdcb2cdcb6905");
    static assert(pins.items[0].dir == "src");
    static assert(pins.items[0].sdk == "0.26.0");
}
