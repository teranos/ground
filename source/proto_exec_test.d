module proto_exec_test;

import proto : parsePbt;
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
