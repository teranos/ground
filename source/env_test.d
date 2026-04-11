module env_test;

import proto : parsePbt, envLookup;

// --- Env lookup CTFE tests ---

// Two projects with different ports
enum envInput = `
project {
  path: "/Users/dev/tmp1/QNTX"
  env {
    port: "8771"
  }
}
project {
  path: "/Users/dev/tmp2/QNTX"
  env {
    port: "8772"
  }
}
`;
enum envParsed = parsePbt(envInput);

// Matches tmp1 project
static assert(envLookup(envParsed, "/Users/dev/tmp1/QNTX/subdir", "port") == "8771");

// Matches tmp2 project
static assert(envLookup(envParsed, "/Users/dev/tmp2/QNTX/subdir", "port") == "8772");

// No matching project — returns null
static assert(envLookup(envParsed, "/Users/dev/other-project", "port") is null);

// Unknown key in matching project — returns null
static assert(envLookup(envParsed, "/Users/dev/tmp1/QNTX", "unknown") is null);

// Multiple env variables
enum multiEnvInput = `
project {
  path: "/app"
  env {
    port: "3000"
    host: "localhost"
  }
}
`;
enum multiEnvParsed = parsePbt(multiEnvInput);
static assert(envLookup(multiEnvParsed, "/app/src", "port") == "3000");
static assert(envLookup(multiEnvParsed, "/app/src", "host") == "localhost");

// Longest path wins
enum overlapInput = `
project {
  path: "/workspace"
  env {
    port: "9000"
  }
}
project {
  path: "/workspace/deep"
  env {
    port: "9001"
  }
}
`;
enum overlapParsed = parsePbt(overlapInput);
static assert(envLookup(overlapParsed, "/workspace/deep/sub", "port") == "9001");
static assert(envLookup(overlapParsed, "/workspace/other", "port") == "9000");
