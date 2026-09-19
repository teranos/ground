module project_test;

// BOOK_GLOSSARY **Project**: A repo ground knows about, by path, whose controls and rituals live beside the code they govern.

import proto : parsePbt;
import proto_test : ctrl, perm;

// --- Project block tests ---

// A project is a repo ground knows about, by the path of its checkout.
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

// Every file git tracks in the checkout, written into the block by wind at
// build. A file named in a reply is then a file ground can ask about.
enum projectWithFilesInput = `
project {
  path: "/Users/me/code/ground"
  files: ["source/main.d", "source/proto.d", "controls/controls.pbt"]
}
`;
enum projectWithFilesParsed = parsePbt(projectWithFilesInput);
static assert(projectWithFilesParsed.projectCount == 1);
static assert(projectWithFilesParsed.projects[0].path == "/Users/me/code/ground");
static assert(projectWithFilesParsed.projects[0].fileCount == 3);
static assert(projectWithFilesParsed.projects[0].files[0] == "source/main.d");
static assert(projectWithFilesParsed.projects[0].files[1] == "source/proto.d");
static assert(projectWithFilesParsed.projects[0].files[2] == "controls/controls.pbt");

// Values a project's controls may use by name, such as the port its server
// listens on.
enum projectWithEnvInput = `
project {
  path: "/Users/Alice/projects/hygrometer-server"
  env {
    port: "8771"
  }
}
`;
enum projectWithEnvParsed = parsePbt(projectWithEnvInput);
static assert(projectWithEnvParsed.projectCount == 1);
static assert(projectWithEnvParsed.projects[0].path == "/Users/Alice/projects/hygrometer-server");
static assert(projectWithEnvParsed.envCount == 1);
static assert(projectWithEnvParsed.envs[0].path == "/Users/Alice/projects/hygrometer-server");
static assert(projectWithEnvParsed.envs[0].keys[0] == "port");
static assert(projectWithEnvParsed.envs[0].values[0] == "8771");
static assert(projectWithEnvParsed.envs[0].count == 1);

// "no double or split config, they all need to go to the same call from the same token"
// "isnt there a top level place where its actually defined"
// The node every project attests to is named once, at the top level, the way
// sentry is: its url and the file holding the token it is spoken to with. A
// project says nothing about the node; what it can say is what of QNTX runs
// beside its checkout.
enum backedInput = `
qntx {
  url:   "https://qntx.alice.example"
  token: "~/.qntx/ground-token"
}

project {
  origin: "alice/QNTX"
  path: "/Users/Alice/projects/QNTX"
  openapi: "server/openapi/openapi.json"
}
`;
enum backedParsed = parsePbt(backedInput);
static assert(backedParsed.qntx.present);
static assert(backedParsed.qntx.url == "https://qntx.alice.example");
static assert(backedParsed.qntx.token == "~/.qntx/ground-token");
static assert(!backedParsed.projects[0].qntx.present, "the project names no loom");
static assert(backedParsed.projects[0].qntx.loomPortUDP == 0);

// "loom is a qntx plugin thing, and we arent using it today"
// "if set, we send to loom, if not set, we dont."
enum loomInput = `
qntx {
  url:   "https://qntx.alice.example"
  token: "~/.qntx/ground-token"
}

project {
  origin: "alice/QNTX"
  path: "/Users/Alice/projects/QNTX"

  qntx {
    loomPortUDP: "19470"
  }
}
`;
enum loomParsed = parsePbt(loomInput);
static assert(loomParsed.projects[0].qntx.present);
static assert(loomParsed.projects[0].qntx.loomPortUDP == 19470);

// The port is where a hook in this project sends; a hook elsewhere sends nowhere.
import ritual : loomPortAt;
static assert(loomPortAt(loomParsed, "/Users/Alice/projects/QNTX") == 19470);
static assert(loomPortAt(loomParsed, "/Users/Alice/projects/QNTX/server") == 19470);
static assert(loomPortAt(loomParsed, "/Users/Alice/projects/other") == 0);
static assert(loomPortAt(backedParsed, "/Users/Alice/projects/QNTX") == 0);

// No node named anywhere: nothing is posted, and nothing pretends to be.
enum nodelessParsed = parsePbt(`project { path: "/p" }`);
static assert(!nodelessParsed.qntx.present);
static assert(nodelessParsed.qntx.url == "");

// "yes, thats the shape, and you can set it top level or inside of project or inside of ritual"
// Every ritual in this project runs under sonnet, unless the ritual sets its own.
enum projectModelsInput = `
project {
  path: "/Users/Alice/projects/hygrometer-server"

  models {
    model: "sonnet"
  }
}
`;
static assert(parsePbt(projectModelsInput).projects[0].models.model == "sonnet");

// --- extractProjectFiles: flatten all project file lists into one array ---

import proto : extractProjectFiles;

// Single project with files
enum singleFiles = extractProjectFiles(projectWithFilesParsed);
static assert(singleFiles.len == 3);
static assert(singleFiles.files[0] == "source/main.d");
static assert(singleFiles.files[1] == "source/proto.d");
static assert(singleFiles.files[2] == "controls/controls.pbt");

// Multiple projects
enum multiProjectInput = `
project {
  path: "/Users/me/code/alpha"
  files: ["src/a.d", "src/b.d"]
}
project {
  path: "/Users/me/code/beta"
  files: ["lib/c.d"]
}
`;
enum multiProjectParsed = parsePbt(multiProjectInput);
enum multiFiles = extractProjectFiles(multiProjectParsed);
static assert(multiFiles.len == 3);
static assert(multiFiles.files[0] == "src/a.d");
static assert(multiFiles.files[1] == "src/b.d");
static assert(multiFiles.files[2] == "lib/c.d");

// Project without files — contributes nothing
enum noFilesFiles = extractProjectFiles(projectStandaloneParsed);
static assert(noFilesFiles.len == 0);

// --- Path list tests ---

// Scope with path list — OR matching
enum pathListInput = `
scope {
  path: ["/ctp/", "/qntx-plugins/"]
  event: "PreToolUse"
  control {
    name: "use-makefile"
    cmd: "cmake"
    msg: "Use the Makefile."
  }
}
`;
enum pathListParsed = parsePbt(pathListInput);
static assert(pathListParsed.scopeCount == 1);
static assert(pathListParsed.scopes[0].pathCount == 2);
static assert(pathListParsed.scopes[0].paths[0] == "/ctp/");
static assert(pathListParsed.scopes[0].paths[1] == "/qntx-plugins/");

// Scope with single path — still works
enum singlePathInput = `
scope {
  path: "/ground"
  event: "PreToolUse"
  control {
    name: "test"
    cmd: "echo"
    msg: "test"
  }
}
`;
enum singlePathParsed = parsePbt(singlePathInput);
static assert(singlePathParsed.scopeCount == 1);
static assert(singlePathParsed.scopes[0].pathCount == 1);
static assert(singlePathParsed.scopes[0].paths[0] == "/ground");
