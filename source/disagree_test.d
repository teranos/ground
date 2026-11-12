module disagree_test;

// "User A keeps both, but ground win's always and the json can't disagree with ground"
// "show the disagreement"

version (Posix):

import disagree;
import permission : Decision;

enum SETTINGS = `{
  "permissions": {
    "allow": [
      "Bash(make test*)",
      "Bash(sed -i *)",
      "WebSearch"
    ],
    "deny": [],
    "ask": [
      "Bash(make install*)"
    ],
    "defaultMode": "auto"
  },
  "model": "fable"
}
`;

// A rule is its tool and the words it stands for, less the wildcard it ends in.
unittest {
    const(char)[] tool, command;
    ruleParts("Bash(make install*)", tool, command);
    assert(tool == "Bash" && command == "make install", command);
    ruleParts("Bash(git commit:*)", tool, command);
    assert(tool == "Bash" && command == "git commit", command);
    ruleParts("WebSearch", tool, command);
    assert(tool == "WebSearch" && command == "", command);
}

// The JSON asks where ground allows, and allows where ground denies: both are
// found, and the rule ground agrees with is not.
unittest {
    FoundIn found;
    disagreementsIn(SETTINGS, "/tmp/somewhere", "auto", found);
    assert(found.count == 2, "two rules say other than ground");
    auto first = SETTINGS[found.all[0].at + 1 .. found.all[0].end - 1];
    auto second = SETTINGS[found.all[1].at + 1 .. found.all[1].end - 1];
    assert(first == "Bash(sed -i *)", first);
    assert(found.all[0].json == Json.allows && found.all[0].ground == Decision.deny);
    assert(second == "Bash(make install*)", second);
    assert(found.all[1].json == Json.asks && found.all[1].ground == Decision.allow);
}

// "remove as in json side"
// Taken out of the JSON, the two are gone, what stays is as it was written,
// and nothing then disagrees.
unittest {
    import matcher : indexOf;
    FoundIn found;
    disagreementsIn(SETTINGS, "/tmp/somewhere", "auto", found);
    char[1024] dest;
    auto n = agreed(SETTINGS, found, dest[]);
    assert(n > 0);
    auto now = dest[0 .. n];
    assert(indexOf(now, "make install") < 0, now);
    assert(indexOf(now, "sed -i") < 0, now);
    assert(indexOf(now, "    \"allow\": [\n      \"Bash(make test*)\",\n      \"WebSearch\"\n    ],") >= 0, now);
    assert(indexOf(now, "\"ask\": []") >= 0, now);
    assert(indexOf(now, "\"defaultMode\": \"auto\"") >= 0, now);
    assert(indexOf(now, "\"model\": \"fable\"") >= 0, now);
    disagreementsIn(now, "/tmp/somewhere", "auto", found);
    assert(found.count == 0, "what is left agrees with ground");
}

// A text that is no settings object, or has no permissions, disagrees with
// nothing and is written back as it is.
unittest {
    FoundIn found;
    disagreementsIn(`{"model": "fable"}`, "/tmp/somewhere", "auto", found);
    assert(found.count == 0);
    char[64] dest;
    auto n = agreed(`{"model": "fable"}`, found, dest[]);
    assert(dest[0 .. n] == `{"model": "fable"}`);
}

// The files read are the person's two and the two of each directory from
// where the session is up to the home.
unittest {
    import core.sys.posix.stdlib : setenv;
    import matcher : indexOf;
    import zbuf : ZBuf;
    setenv("HOME", "/tmp/ground-disagree-home", 1);
    ZBuf paths;
    settingsFiles("/tmp/ground-disagree-home/work/repo", paths);
    auto all = paths.slice();
    assert(indexOf(all, "/tmp/ground-disagree-home/.claude/settings.json\0") == 0, all);
    assert(indexOf(all, "/tmp/ground-disagree-home/work/repo/.claude/settings.local.json\0") > 0, all);
    assert(indexOf(all, "/tmp/ground-disagree-home/work/.claude/settings.json\0") > 0, all);
    size_t count = 0;
    foreach (c; all) if (c == 0) count++;
    assert(count == 6, "the home's two, the repo's two, and the two of the directory between");
}
