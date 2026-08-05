module rite_script_test;

// The text a rite actually runs.
// Brandon: "wouldnt the pipefail need to be present essentially everywhere?"

import rite : buildRiteScript, RiteScript;

// Every rite runs under the same three flags. They are not hygiene — each
// one closes a way a rite can report a pass it did not earn.
enum bare = buildRiteScript("make parity", [], []);
static assert(bare.text() == "#!/usr/bin/env bash\nset -euo pipefail\nmake parity\n");

// -o pipefail: `make parity | grep row` without it returns grep's status, so
// a crashed make reads as "the row is not YES YES" — a finding, not a fault.
// With it, make's code propagates and the rite halts on it instead.
enum piped = buildRiteScript(`make parity | grep "$row"`, [], []);
static assert(piped.text() == "#!/usr/bin/env bash\nset -euo pipefail\nmake parity | grep \"$row\"\n");

// "how do i set the row param from the ritual"
// A param is an assignment above the command, in the script the operator can
// read, not an environment the operator has to be told about.
enum withParam = buildRiteScript(`grep "$row"`, ["row"], ["watchers"]);
static assert(withParam.text() ==
    "#!/usr/bin/env bash\nset -euo pipefail\nrow='watchers'\ngrep \"$row\"\n");

// Order is declaration order, so the script reads the way the pbt reads.
enum twoParams = buildRiteScript("echo", ["row", "pr"], ["watchers", "833"]);
static assert(twoParams.text() ==
    "#!/usr/bin/env bash\nset -euo pipefail\nrow='watchers'\npr='833'\necho\n");

// -u: an unsupplied param is an unset variable, and the script dies on it.
// Without -u it expands to empty, and `grep ""` matches every line — the
// false pass CTFE item 11 refuses at build time and this refuses at run time.
enum unsupplied = buildRiteScript(`grep "$row"`, [], []);
static assert(unsupplied.text() == "#!/usr/bin/env bash\nset -euo pipefail\ngrep \"$row\"\n");

// A single quote in a value would close the quoting and hand the rest of the
// value to the shell as code.
enum quoted = buildRiteScript("echo", ["msg"], ["it's"]);
static assert(quoted.text() == "#!/usr/bin/env bash\nset -euo pipefail\nmsg='it'\\''s'\necho\n");

// --- What envSubst leaves behind ---
// "i found a TODO at the top in controls/local/sbvh.pbt" / "env block right?"

import rite : hasUnresolved;

// envSubst returns an unknown ${key} unchanged (matcher.d:862). In a msg that
// is a cosmetic defect. In a rite it is a command with a hole in it.
static assert(hasUnresolved("curl -sf ${api}/api/plugins"));
static assert(!hasUnresolved("curl -sf https://api.q.sbvh.nl/api/plugins"));

// $row is a shell variable the script assigns itself, not a project env key.
static assert(!hasUnresolved(`make parity | grep "$row *YES *YES"`));

// A bare $ or a { on its own is not a placeholder.
static assert(!hasUnresolved("echo $HOME"));
static assert(!hasUnresolved("awk '{print $1}'"));

// A ${key} no project env resolves leaves the rite unready, and an unready
// rite has no script to run.
import rite : prepareRite;
import proto : parsePbt;

unittest {
    enum src = `rites x { a { cmd: "curl -sf ${api}/z" } }`;
    enum r = parsePbt(src).rites[0].rites[0];
    auto p = prepareRite(r, "/no/project/matches/this");
    assert(!p.ready);
    assert(p.script.len == 0);
}

unittest {
    enum src = `rites x { a { cmd: "make parity" } }`;
    enum r = parsePbt(src).rites[0].rites[0];
    auto p = prepareRite(r, "/no/project/matches/this");
    assert(p.ready);
    assert(p.script.text() == "#!/usr/bin/env bash\nset -euo pipefail\nmake parity\n");
}

// --- The flags against a real shell ---

import rite : runRite;

private int codeOf(const(char)[] cmd, const(char[])[] k = [], const(char[])[] v = []) {
    return runRite(buildRiteScript(cmd, k, v).text()).code;
}

unittest {
    assert(codeOf("true") == 0);
    assert(codeOf("false") == 1);
}

unittest {
    // Without -o pipefail this is 0: the pipeline reports only `true`.
    assert(codeOf("false | true") == 1);
}

unittest {
    // Without -u this echoes an empty line and exits 0.
    assert(codeOf(`echo "$notset"`) != 0);
}

unittest {
    // Without -e the script's status is the last command's, so a failure in
    // the middle is erased by anything that succeeds after it.
    assert(codeOf("false; true") == 1);
}

unittest {
    // A command that does not exist. The one a two-outcome gate cannot tell
    // apart from a finding.
    assert(codeOf("definitely-not-a-command") == 127);
}

unittest {
    static immutable const(char)[][1] k = ["row"];
    static immutable const(char)[][1] v = ["watchers"];
    auto r = runRite(buildRiteScript(`echo "$row"`, k[], v[]).text());
    assert(r.code == 0);
    assert(r.output() == "watchers\n");
}

unittest {
    // Output is captured on failure too — it is what goes on screen at Halt.
    auto r = runRite(buildRiteScript("echo before; false", [], []).text());
    assert(r.code == 1);
    assert(r.output() == "before\n");
}
