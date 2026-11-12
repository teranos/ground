module project_test;

// BOOK_GLOSSARY **Project**: A repo ground knows about, by path, whose controls and rituals live beside the code they govern.

import proto : parsePbt;
import proto_test : ctrl, perm;

// --- Project block tests ---

// book: project-projectStandaloneInput
enum projectStandaloneInput = `
project {
  path: "/Users/me/code/ground"
}
`;
enum projectStandaloneParsed = parsePbt(projectStandaloneInput);
static assert(projectStandaloneParsed.projectCount == 1);
static assert(projectStandaloneParsed.projects[0].path == "/Users/me/code/ground");

// book: project-projectWithChildrenInput
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

// book: project-projectInScopeInput
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

// book: project-projectWithControlInput
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

// book: project-projectWithFilesInput
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

// book: project-projectWithEnvInput
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

// "isnt there a top level place where its actually defined"
// book: project-backedInput
enum backedInput = `
qntx {
  url: "https://qntx.alice.example"
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

// "I'm saying, I want to kill it, and make sure QNTX takes over"
// "All the UDP machinery can also go given how sky handles it"
// book: project-loomInput
enum loomInput = `
project {
  path: "/Users/Alice/projects/QNTX"

  qntx {
    loomPortUDP: "19470"
  }
}
`;
static assert(!__traits(compiles, { enum bad = parsePbt(loomInput); }));
static assert(!__traits(compiles, { enum bad = parsePbt(`qntx {
  url: "https://qntx.alice.example"
  loomPortUDP: "19470"
}`); }));

// No node named anywhere: nothing is posted, and nothing pretends to be.
enum nodelessParsed = parsePbt(`project { path: "/p" }`);
static assert(!nodelessParsed.qntx.present);
static assert(nodelessParsed.qntx.url == "");

// "yes, thats the shape, and you can set it top level or inside of project or inside of ritual"
// book: project-projectModelsInput
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

// book: project-multiProjectInput
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

// book: project-pathListInput
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

// book: project-singlePathInput
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
