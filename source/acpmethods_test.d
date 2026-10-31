module acpmethods_test;

import acpmethods;

// Each group's names from schema-v1.26.0's meta.json, as the TypeScript SDK names them: AGENT_METHODS,
// CLIENT_METHODS and PROTOCOL_METHODS, each name to its wire name.
static assert(AGENT_METHODS.initialize == "initialize");
static assert(AGENT_METHODS.session_new == "session/new");
static assert(AGENT_METHODS.session_set_config_option == "session/set_config_option");
static assert(AGENT_METHODS.logout == "logout");
static assert(CLIENT_METHODS.session_request_permission == "session/request_permission");
static assert(CLIENT_METHODS.fs_write_text_file == "fs/write_text_file");
static assert(CLIENT_METHODS.terminal_wait_for_exit == "terminal/wait_for_exit");
static assert(PROTOCOL_METHODS.cancel_request == "$/cancel_request");
// Every one: 13 agent methods, 11 client methods, 1 protocol method.
static assert(__traits(allMembers, AGENT_METHODS).length == 13);
static assert(__traits(allMembers, CLIENT_METHODS).length == 11);
static assert(__traits(allMembers, PROTOCOL_METHODS).length == 1);
// A method's wire name, and the name it has there, for one read off the wire.
static assert(methodNamed("session/prompt") == "AGENT_METHODS.session_prompt");
static assert(methodNamed("terminal/kill") == "CLIENT_METHODS.terminal_kill");
static assert(methodNamed("session/wiggle") is null);
static assert(wireOf("CLIENT_METHODS.terminal_kill") == "terminal/kill");
static assert(wireOf("AGENT_METHODS.nothing") is null);
// And as libacp's acp_methods.h names it, from the same file.
static assert(wireOfMacro("ACP_CLIENT_TERMINAL_WAIT_FOR_EXIT") == "terminal/wait_for_exit");
static assert(wireOfMacro("ACP_PROTOCOL_CANCEL_REQUEST") == "$/cancel_request");
static assert(wireOfMacro("ACP_CLIENT_NOTHING") is null);
