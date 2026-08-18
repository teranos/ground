module rite_script_test;

// The text a rite actually runs.
// Brandon: "wouldnt the pipefail need to be present essentially everywhere?"

import rite : buildRiteScript, RiteScript, RITE_UNREACHED, runRite;

// Every rite runs under the same three flags. They are not hygiene — each
// one closes a way a rite can report a pass it did not earn.
enum bare = buildRiteScript("", "make parity", [], []);
static assert(bare.text() == "#!/usr/bin/env bash\nset -euo pipefail\nmake parity\n");

// -o pipefail: `make parity | grep row` without it returns grep's status, so
// a crashed make reads as "the row is not YES YES" — a finding, not a fault.
// With it, make's code propagates and the rite halts on it instead.
enum piped = buildRiteScript("", `make parity | grep "$row"`, [], []);
static assert(piped.text() == "#!/usr/bin/env bash\nset -euo pipefail\nmake parity | grep \"$row\"\n");

// "how do i set the row param from the ritual"
// A param is an assignment above the command, in the script the operator can
// read, not an environment the operator has to be told about.
enum withParam = buildRiteScript("", `grep "$row"`, ["row"], ["watchers"]);
static assert(withParam.text() ==
    "#!/usr/bin/env bash\nset -euo pipefail\nrow='watchers'\ngrep \"$row\"\n");

// Order is declaration order, so the script reads the way the pbt reads.
enum twoParams = buildRiteScript("", "echo", ["row", "pr"], ["watchers", "833"]);
static assert(twoParams.text() ==
    "#!/usr/bin/env bash\nset -euo pipefail\nrow='watchers'\npr='833'\necho\n");

// -u: an unsupplied param is an unset variable, and the script dies on it.
// Without -u it expands to empty, and `grep ""` matches every line — the
// false pass CTFE item 11 refuses at build time and this refuses at run time.
enum unsupplied = buildRiteScript("", `grep "$row"`, [], []);
static assert(unsupplied.text() == "#!/usr/bin/env bash\nset -euo pipefail\ngrep \"$row\"\n");

// A single quote in a value would close the quoting and hand the rest of the
// value to the shell as code.
enum quoted = buildRiteScript("", "echo", ["msg"], ["it's"]);
static assert(quoted.text() == "#!/usr/bin/env bash\nset -euo pipefail\nmsg='it'\\''s'\necho\n");

// The rite runs in the performance's tree, and whoever runs it is not
// standing there. The cd is in the script so the rite stays one thing you
// can print and run by hand.
enum located = buildRiteScript("/home/u/src/proj-probe", "make test", [], []);
static assert(located.text() ==
    "#!/usr/bin/env bash\nset -euo pipefail\ncd '/home/u/src/proj-probe' || exit 125\nmake test\n");

// Reaching the tree is not the condition. Silence about catch means 1, set in
// `parseRites`, so a cd that failed with 1 read as "not yet" — measured:
// a performance recorded "the fruit is still hanging" when the tree was gone.
unittest {
    auto r = runRite(buildRiteScript("/no/such/tree/anywhere", "true", [], []).text());
    assert(r.code == RITE_UNREACHED);
    assert(r.code != 0);
    assert(r.code != 1);
}

// --- What envSubst leaves behind ---
// "i found a TODO at the top in controls/local/x.pbt" / "env block right?"

import rite : hasUnresolved;

// envSubst returns an unknown ${key} unchanged. In a msg that
// is a cosmetic defect. In a rite it is a command with a hole in it.
static assert(hasUnresolved("curl -sf ${api}/api/plugins"));
static assert(!hasUnresolved("curl -sf https://api.example.invalid/api/plugins"));

// $row is a shell variable the script assigns itself, not a project env key.
static assert(!hasUnresolved(`make parity | grep "$row *YES *YES"`));

// A bare $ or a { on its own is not a placeholder.
static assert(!hasUnresolved("echo $HOME"));
static assert(!hasUnresolved("awk '{print $1}'"));

// --- What a rite may not do to its own exit code ---
// "ground uses those exit codes, becaue not all failures are the same failure"

import rite : launders;

// A code the author wrote is not a code the tool produced, and everything
// ground does with a rite reads the code.
static assert(launders(`gh pr create --fill || true`));
static assert(launders(`curl -sf ${api}/health || exit 0`));

// The number is not the point. Any code the author picks is a code the tool
// did not produce.
static assert(launders(`curl -sf ${api}/health || exit 33`));
static assert(launders(`curl -sf ${api}/health || exit 55`));
static assert(launders(`curl -sf ${api}/health || exit 1`));

// `:` is `true` spelled shorter and does the same damage.
static assert(launders(`make build || :`));

// Spacing is the author's, not a signal.
static assert(launders(`cmd||true`));
static assert(launders(`cmd ||  exit 0`));

// A tool left to answer for itself is what every rite should look like.
static assert(!launders(`git log --oneline HEAD | grep -q .`));
static assert(!launders(`test -f WILLOW.md`));

// Nowhere means nowhere. Inside a substitution it still suppresses the tool,
// and quoting it does not make it not there.
static assert(launders(`test "$(grep -cF "  - " WILLOW.md || true)" = "0"`));
static assert(launders(`gh pr create --fill 2>&1 || true`));

// A command with no `||` in it is untouched.
static assert(!launders(`grep -qxF "  - TRUE" WILLOW.md`));

// A ${key} no project env resolves leaves the rite unready, and an unready
// rite has no script to run.
import rite : prepareRite;
import proto : parsePbt;

unittest {
    enum src = `rites x { a { eval: "curl -sf ${api}/z" } }`;
    enum r = parsePbt(src).rites[0].rites[0];
    auto p = prepareRite(r, "/no/project/matches/this");
    assert(!p.ready);
    assert(p.script.len == 0);
}

unittest {
    enum src = `rites x { a { eval: "make parity" } }`;
    enum r = parsePbt(src).rites[0].rites[0];
    auto p = prepareRite(r, "/no/project/matches/this");
    assert(p.ready);
    // prepareRite's cwd is the performance's tree, so it is both what envSubst
    // resolves against and where the rite runs.
    assert(p.script.text() ==
        "#!/usr/bin/env bash\nset -euo pipefail\ncd '/no/project/matches/this' || exit 125\nmake parity\n");
}

// --- The flags against a real shell ---

import rite : runRite;

private int codeOf(const(char)[] cmd, const(char[])[] k = [], const(char[])[] v = []) {
    return runRite(buildRiteScript("", cmd, k, v).text()).code;
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
    auto r = runRite(buildRiteScript("", `echo "$row"`, k[], v[]).text());
    assert(r.code == 0);
    assert(r.output() == "watchers\n");
}

unittest {
    // Output is captured on failure too — it is what goes on screen at Halt.
    auto r = runRite(buildRiteScript("", "echo before; false", [], []).text());
    assert(r.code == 1);
    assert(r.output() == "before\n");
}
