module proto_exec_test;

import proto : parsePbt, buildScopes;
import proto_test : ctrl;

// > "I have a hook system. I could run code always after you do a push
// > automatically in the QNTX repo."
//
// > "We could extend ground to run specified .fish files on certain
// > event cwd matches, inside of the claude code session, and report
// > back when it's completed via ground watch."
//
// > "I do want exec."
//
// > "Yeah, just don't be fucking stupid about what you put in the exec
// > scripts."
//
// The control this was designed for:
//
//   scope {
//     path: "/QNTX"
//     event: "PostToolUse"
//     cmd: "git push"
//     control {
//       name: "q-web-deploy-on-push"
//       exec: "<path-to-deploy-q-web.fish>"
//     }
//   }

enum execInput = `
scope {
  path: "/QNTX"
  event: "PostToolUse"
  cmd: "git push"
  control {
    name: "q-web-deploy-on-push"
    exec: "/tmp/deploy-q-web.fish"
  }
}
`;
enum execParsed = parsePbt(execInput);
static assert(ctrl(execParsed, 0, 0).name == "q-web-deploy-on-push");
static assert(ctrl(execParsed, 0, 0).exec == "/tmp/deploy-q-web.fish");

// buildScopes wires exec through to the runtime Control struct.
enum execBuilt = buildScopes(execParsed, "PostToolUse");
static assert(execBuilt.items[0].controls[0].exec == "/tmp/deploy-q-web.fish");

// Control-level env { } block — the pbt-declarative way to configure the
// exec child. Same block shape as `project { env { … } }`, but attached to
// a control. Reads at exec-fire time; the child sees these as env vars.
enum execWithEnvInput = `
scope {
  path: "/QNTX"
  event: "PostToolUse"
  cmd: "git push"
  control {
    name: "q-web-deploy-on-push"
    exec: "/tmp/deploy-q-web.fish"
    env {
      target: "production"
      api_key_var: "PROD_KEY"
    }
  }
}
`;
enum execWithEnvParsed = parsePbt(execWithEnvInput);
static assert(ctrl(execWithEnvParsed, 0, 0).envCount == 2);
static assert(ctrl(execWithEnvParsed, 0, 0).envKeys[0] == "target");
static assert(ctrl(execWithEnvParsed, 0, 0).envValues[0] == "production");
static assert(ctrl(execWithEnvParsed, 0, 0).envKeys[1] == "api_key_var");
static assert(ctrl(execWithEnvParsed, 0, 0).envValues[1] == "PROD_KEY");

// buildScopes carries env through to runtime Control.
enum execWithEnvBuilt = buildScopes(execWithEnvParsed, "PostToolUse");
static assert(execWithEnvBuilt.items[0].controls[0].envCount == 2);
static assert(execWithEnvBuilt.items[0].controls[0].envKeys[0] == "target");
static assert(execWithEnvBuilt.items[0].controls[0].envValues[0] == "production");
