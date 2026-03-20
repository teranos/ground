module macos;

import hooks;
import proto : parsePbt, buildScopes;

enum macosParsed = parsePbt(import("controls/macos.pbt"));

enum macosScopes = buildScopes(macosParsed, "PreToolUse");
enum macosUserPromptScopes = buildScopes(macosParsed, "UserPromptSubmit");
