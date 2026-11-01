module machine_test;

import machine : namesNode;

// A repository whose controls name the node, at the top level, is a machine's: its controls go only
// into its own machine's sand, never into a sand that declares it as a project.
static assert(namesNode("# k\nqntx {\n  url: \"http://10.88.0.2:8770\"\n}\n"));
static assert(namesNode("qntx{\n  url: \"x\"\n}\n"));

// A project's controls name no node: a qntx block nested in another, or none at all.
static assert(!namesNode("project {\n  qntx {\n    url: \"x\"\n  }\n}\n"));
static assert(!namesNode("scope {\n  event: \"PreToolUse\"\n}\n"));
static assert(!namesNode("# qntx {\n"));
static assert(!namesNode("qntxish {\n}\n"));
