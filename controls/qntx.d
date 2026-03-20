module qntx;

import hooks;
import proto : parsePbt, buildScopes;

enum qntxParsed = parsePbt(import("controls/qntx.pbt"));

enum qntxScopes = buildScopes(qntxParsed, "PreToolUse");
enum qntxFileScopes = buildScopes(qntxParsed, "PreToolUseFile");
enum qntxUserPromptScopes = buildScopes(qntxParsed, "UserPromptSubmit");
enum qntxPreCompactScopes = buildScopes(qntxParsed, "PreCompact");
