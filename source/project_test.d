module project_test;

import proto : parsePbt;
import proto_test : ctrl, perm;

// --- Project block tests ---

// Standalone project — just a path for wind
enum projectStandaloneInput = `
project {
  path: "/Users/me/code/ground"
}
`;
enum projectStandaloneParsed = parsePbt(projectStandaloneInput);
static assert(projectStandaloneParsed.projectCount == 1);
static assert(projectStandaloneParsed.projects[0].path == "/Users/me/code/ground");

// Project with children — scopes, controls, permissions all work inside
enum projectWithChildrenInput = `
project {
  path: "/Users/me/code/myproject"

  scope {
    event: "PreToolUse"
    control {
      name: "proj-ctrl"
      cmd: "make"
      msg: "build reminder"
    }
  }

  permission {
    allow: ["make*"]
  }
}
`;
enum projectWithChildrenParsed = parsePbt(projectWithChildrenInput);
static assert(projectWithChildrenParsed.projectCount == 1);
static assert(projectWithChildrenParsed.projects[0].path == "/Users/me/code/myproject");
static assert(projectWithChildrenParsed.scopeCount == 2); // scope + permission-wrapped-in-scope
static assert(projectWithChildrenParsed.scopes[0].event == "PreToolUse");
static assert(ctrl(projectWithChildrenParsed, 0, 0).name == "proj-ctrl");
static assert(projectWithChildrenParsed.permPoolLen == 1);

// Project inside a scope
enum projectInScopeInput = `
scope {
  event: "PreToolUse"
  project {
    path: "/Users/me/code/nested"
  }
}
`;
enum projectInScopeParsed = parsePbt(projectInScopeInput);
static assert(projectInScopeParsed.projectCount == 1);
static assert(projectInScopeParsed.projects[0].path == "/Users/me/code/nested");

// Project with control directly (no scope wrapper)
enum projectWithControlInput = `
project {
  path: "/Users/me/code/direct"
  control {
    name: "direct-ctrl"
    cmd: "echo"
    msg: "test"
  }
}
`;
enum projectWithControlParsed = parsePbt(projectWithControlInput);
static assert(projectWithControlParsed.projectCount == 1);
static assert(projectWithControlParsed.scopeCount == 1);
static assert(ctrl(projectWithControlParsed, 0, 0).name == "direct-ctrl");
