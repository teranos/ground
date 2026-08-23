module playbill_test;

// What a session in this project is told about the rituals that could fire.

import proto : parsePbt;
import controls : allParsed;
import playbill : cuesOf, billInto, ritualCues;

// One cue per control that names a ritual, counted from the compiled set. A
// build with no controls has none of either, which is what CI compiles.
private enum namingRituals = () {
    size_t n = 0;
    foreach (si; 0 .. allParsed.scopeCount) {
        auto sc = allParsed.scopes[si];
        foreach (ci; sc.controlStart .. sc.controlEnd)
            if (allParsed.ctrlPool[ci].ritual.length > 0) n++;
    }
    return n;
}();
static assert(ritualCues.length == namingRituals);

// A checkout with no control directories on it compiles no controls, so the
// table is empty and the count above is zero on both sides. This is CI.
static assert(cuesOf(parsePbt("")).len == 0);

enum src = `
rites deployment {
  BRANCH { eval: "true" }
  SACRED { eval: "true"  to: parent }
}

scope {
  path:  ["/teranos/QNTX", "!/teranos/QNTX-App"]
  event: "PostToolUse"
  cmd:   "git push"

  control {
    name: "q-deploy"
    ritual { deployment }
  }
}
`;
enum parsed = parsePbt(src);
enum bill = cuesOf(parsed);

// One control names one ritual, so there is one cue.
static assert(bill.len == 1);
static assert(bill.cues[0].ritual == "q-deploy");
static assert(bill.cues[0].event == "PostToolUse");
static assert(bill.cues[0].cmdCount == 1);
static assert(bill.cues[0].cmds[0] == "git push");

// The rite names in the order the walk takes them, which are the names a halt
// line names. Without them SACRED arrives as a word from nowhere.
static assert(bill.cues[0].riteCount == 2);
static assert(bill.cues[0].rites[0] == "BRANCH");
static assert(bill.cues[0].rites[1] == "SACRED");

size_t drawnLen(const(char)[] cwd)() {
    char[512] buf = '.';
    return billInto(bill.cues[0 .. bill.len], cwd, buf[]);
}

char[512] drawn(const(char)[] cwd)() {
    char[512] buf = '.';
    billInto(bill.cues[0 .. bill.len], cwd, buf[]);
    return buf;
}

enum want = "q-deploy performs here on `git push` (PostToolUse): BRANCH > SACRED";
static assert(drawnLen!"/Users/x/teranos/QNTX"() == want.length);
static assert(drawn!"/Users/x/teranos/QNTX"()[0 .. want.length] == want);

// The negation belongs to the scope, so the app repo is told nothing — the
// same rule that decides whether the ritual fires decides whether it is named.
static assert(drawnLen!"/Users/x/teranos/QNTX-App"() == 0);

// Nowhere near it, nothing to say.
static assert(drawnLen!"/Users/x/other"() == 0);

// A scope with no cmd is started by the event alone, and the sentence says so
// rather than leaving an empty pair of backticks.
enum eventOnly = `
rites watch { LOOK { eval: "true" } }

scope {
  path:  "/sbvh-nl/grove"
  event: "Stop"

  control {
    name: "vigil"
    ritual { watch }
  }
}
`;
enum eventBill = cuesOf(parsePbt(eventOnly));

size_t eventLen(const(char)[] cwd)() {
    char[512] buf = '.';
    return billInto(eventBill.cues[0 .. eventBill.len], cwd, buf[]);
}

char[512] eventDrawn(const(char)[] cwd)() {
    char[512] buf = '.';
    billInto(eventBill.cues[0 .. eventBill.len], cwd, buf[]);
    return buf;
}

enum eventWant = "vigil performs here on Stop: LOOK";
static assert(eventLen!"/x/sbvh-nl/grove"() == eventWant.length);
static assert(eventDrawn!"/x/sbvh-nl/grove"()[0 .. eventWant.length] == eventWant);
