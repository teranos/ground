module regoto_test;

// BOOK_GLOSSARY **Regoto**: The rite a ritual's live performance goes to when the ritual fires again. Without one, every fire is a performance of its own.

import proto : parsePbt, validateRituals;

// "a ritual is running"
// "the same ritual fires again, a 2nd instance"
// "the 2nd instance sees there is already one running, the ritual never runs"
// "think of it like a goto"
// "the parameter is the rite"
// A second fire starts no performance. The live one's tree is brought onto the push, its walk goes to the named rite with its counts started over, and its agent and parent are told.
// A fire after the regoto rite sends the walk back to it: regoto-walk on W3, pushed again, stood on W2 in the same row, its tree at the new push.
// TODO open: a fire that lands before the regoto rite jumps forward to it, W1 to W2. Whether to keep that is undecided.
// TODO open: without a tree of its own a regoto moves the checkout the ritual fired from. Whether the parser should refuse regoto without tree is undecided.
enum withRegoto = `
rites steps {
  STEP1 {
    eval: "echo 'step' > steps.txt"
  }
  STEP2 {
    eval: "echo 'step' > steps.txt"
  }
  STEP3 {
    eval: "echo 'step' > steps.txt"
  }
  END {
    eval: "echo 'finished' > steps.txt"
  }
}

project {
  path: "/alice/smartwatchapp"

  ritual stepcounter {
    regoto: STEP2
    tree: "checkout"
    steps
  }
}
`;

static assert(parsePbt(withRegoto).rituals[0].regoto == "STEP2");
static assert(validateRituals(parsePbt(withRegoto)).text() == "");

// "its an opt-in as well, this behaviour"
// "a ritual that hasnt opted in behaves like it does today, parralel agent sessions in individual rituals"
enum withoutRegoto = `
rites judged {
  ROUTE {
    eval: "true"
  }
}

project {
  path: "/teranos/QNTX"

  ritual deploy {
    judged
  }
}
`;
static assert(parsePbt(withoutRegoto).rituals[0].regoto == "");

// "why not regoto"
// A regoto naming no rite of its own ritual is a jump into the dark, as a goto is.
enum badRegoto = `
rites judged {
  ROUTE {
    eval: "true"
  }
}

project {
  path: "/teranos/QNTX"

  ritual deploy {
    regoto: nowhere
    judged
  }
}
`;
static assert(validateRituals(parsePbt(badRegoto)).text() == "ritual deploy: regoto names no rite: nowhere");

import ritual : secondFire, writePosition, start, RitualState;
import db : sqlite3, sqlite3_open, sqlite3_close, applySchema, SQLITE_OK;

private sqlite3* memDb() {
    sqlite3* db;
    assert(sqlite3_open(":memory:\0".ptr, &db) == SQLITE_OK);
    assert(applySchema(db));
    return db;
}

private void performing(sqlite3* db, string ritual, string id, RitualState st) {
    auto p = start(ritual, 4);
    p.id = id;
    p.repo = "/alice/smartwatchapp";
    p.rites = "STEP1,STEP2,STEP3,END";
    p.state = st;
    assert(writePosition(db, p));
}

unittest {
    // A second fire of a ritual that opted in, with a performance of it live,
    // starts nothing.
    auto db = memDb();
    performing(db, "stepcounter", "stepcounter-1000", RitualState.Live);
    assert(secondFire(db, parsePbt(withRegoto), "stepcounter")
           == "stepcounter-1000 is live, so no second performance of stepcounter starts");
    sqlite3_close(db);
}

unittest {
    // A performance that ended is not one a fire can land on. The next push
    // after a walk has ended starts a new performance.
    auto db = memDb();
    performing(db, "stepcounter", "stepcounter-1000", RitualState.Done);
    assert(secondFire(db, parsePbt(withRegoto), "stepcounter") is null);
    sqlite3_close(db);
}

unittest {
    // Without regoto, every fire is its own performance, live one or not.
    auto db = memDb();
    performing(db, "deploy", "deploy-1000", RitualState.Live);
    assert(secondFire(db, parsePbt(withoutRegoto), "deploy") is null);
    sqlite3_close(db);
}

// The ADR-018 push landed on q-deploy-1790673902 in W500 and gave up: the row
// was written again while the tree was being moved.
unittest {
    import ritual : sendBack, byPerformanceId, Position;
    auto db = memDb();
    performing(db, "stepcounter", "stepcounter-1000", RitualState.Live);
    auto seen = byPerformanceId(db, "stepcounter-1000");
    auto other = seen.p;
    other.current = 3;
    assert(writePosition(db, other), "somebody else writes the row");

    Position landed;
    assert(sendBack(db, "stepcounter-1000", 1, landed).length == 0);
    auto got = byPerformanceId(db, "stepcounter-1000");
    assert(got.p.current == 1 && got.p.state == RitualState.Live);
    assert(landed.current == 1);
    sqlite3_close(db);
}

// "because the new one should be the one that is the change"
// The push a performance walks for is kept beside it, and only a push writes
// it: a rite that finishes after a landing cannot put the old push back.
unittest {
    import ritual : setPush, readPush, byPerformanceId;
    auto db = memDb();
    performing(db, "stepcounter", "stepcounter-1000", RitualState.Live);
    assert(setPush(db, "stepcounter-1000", "plugin-element", "git push", "a..b  plugin-element -> plugin-element"));
    auto late = byPerformanceId(db, "stepcounter-1000").p;
    late.branch = "github-service-root";
    assert(writePosition(db, late));
    auto push = readPush(db, "stepcounter-1000");
    assert(push.branch() == "plugin-element");
    assert(push.input() == "git push");
    assert(push.output() == "a..b  plugin-element -> plugin-element");
    sqlite3_close(db);
}

// A performance that ended while the tree was being moved is not sent back.
unittest {
    import ritual : sendBack, Position;
    auto db = memDb();
    performing(db, "stepcounter", "stepcounter-1000", RitualState.Halted);
    Position landed;
    assert(sendBack(db, "stepcounter-1000", 1, landed) == "it ended before it could be sent back");
    sqlite3_close(db);
}

// The walk goes back like a goto, and what it counted starts over, so every
// eval is asked again. The rites before it keep what they were.
unittest {
    import ritual : rewind, RiteState;
    auto p = start("stepcounter", 4);
    p.current = 3;
    p.states[0] = RiteState.Passed;
    p.states[1] = RiteState.Passed;
    p.states[2] = RiteState.Passed;
    p.gotos = 2; p.evals = 5; p.holds = 3; p.throws = 1;
    p.states[3] = RiteState.Running;
    auto q = rewind(p, 1);
    assert(q.current == 1);
    assert(q.gotos == 0 && q.evals == 0 && q.holds == 0 && q.throws == 0);
    assert(q.state == RitualState.Live);
    // What stands before the rite it went to keeps what it was. From there on
    // every rite is to be walked again, so none of them is running or passed:
    // W3 still drawn running beside W2 read as two rites live at once.
    assert(q.states[0] == RiteState.Passed);
    assert(q.states[1] == RiteState.Never);
    assert(q.states[2] == RiteState.Never);
    assert(q.states[3] == RiteState.Never);
}

// Real repos: a bare origin, a checkout that pushes, and a performance's tree
// cut from that checkout the way ground cuts one.
import core.stdc.stdlib : system, getenv;
extern (C) char* mkdtemp(char* template_);

// No GC under betterC, so every path and command is set into a buffer.
private struct Buf {
    char[1024] b = 0;
    size_t n;
    void put(const(char)[] s) { foreach (c; s) if (n < b.length - 1) b[n++] = c; }
    const(char)[] text() const return { return b[0 .. n]; }
    const(char)* z() return { b[n] = 0; return b.ptr; }
}

private void sh(A...)(A parts) {
    // In a subshell, so a command's own redirect is not overruled by the
    // silencing one after it: printf into a file wrote the file empty.
    Buf c;
    c.put("( ");
    foreach (p; parts) c.put(p);
    c.put(" )");
    auto bare = c.n;
    c.put(" >/dev/null 2>&1");
    if (system(c.z()) == 0) return;
    // Said again with its output, so a failure carries git's own reason.
    c.n = bare;
    cast(void) system(c.z());
    assert(false, c.text());
}

import core.stdc.stdio : FILE;
extern (C) FILE* popen(const(char)* command, const(char)* mode);
extern (C) int pclose(FILE* stream);

private Buf gitOut(A...)(const(char)[] tree, A args) {
    import core.stdc.stdio : fread;
    Buf c;
    c.put("git -C '");
    c.put(tree);
    c.put("' ");
    foreach (a; args) c.put(a);
    auto f = popen(c.z(), "r");
    Buf o;
    o.n = fread(o.b.ptr, 1, o.b.length - 1, f);
    pclose(f);
    while (o.n > 0 && o.b[o.n - 1] == '\n') o.n--;
    return o;
}

private struct Stage { Buf root, pusher, tree; }

private Stage stage() {
    Stage s;
    auto base = getenv("TMPDIR");
    size_t n;
    if (base !is null) while (base[n]) n++;
    const(char)[] dir = base is null ? "/tmp" : base[0 .. n];
    if (dir.length > 0 && dir[$ - 1] == '/') dir = dir[0 .. $ - 1];
    s.root.put(dir);
    s.root.put("/ground-regoto-XXXXXX");
    assert(mkdtemp(cast(char*) s.root.z()) !is null);
    s.pusher.put(s.root.text());
    s.pusher.put("/pusher");
    s.tree.put(s.root.text());
    s.tree.put("/pusher-stepcounter-1000");
    auto root = s.root.text(), pusher = s.pusher.text(), tree = s.tree.text();
    sh("git init -q --bare '", root, "/origin.git'");
    sh("git clone -q '", root, "/origin.git' '", pusher, "'");
    sh("git -C '", pusher, "' config user.name ground");
    sh("git -C '", pusher, "' config user.email ground@example.invalid");
    sh("git -C '", pusher, "' checkout -q -b main");
    sh("printf 'one\\n' > '", pusher, "/steps.txt'");
    sh("git -C '", pusher, "' add steps.txt");
    sh("git -C '", pusher, "' commit -q -m one");
    sh("git -C '", pusher, "' push -q origin main");
    sh("git -C '", pusher, "' worktree add -q '", tree, "'");
    return s;
}

// The second push: a change the performance's tree has not seen.
private Buf push(ref Stage s, const(char)[] line) {
    auto pusher = s.pusher.text();
    sh("printf '", line, "\\n' >> '", pusher, "/steps.txt'");
    sh("git -C '", pusher, "' commit -q -am ", line);
    sh("git -C '", pusher, "' push -q origin main");
    return gitOut(pusher, "rev-parse HEAD");
}

unittest {
    // Work the agent had not committed is stashed, the push pulled, the work put back.
    import ritual : moveTree;
    auto s = stage();
    sh("printf 'mine\\n' > '", s.tree.text(), "/notes.txt'");
    auto commit = push(s, "two");
    auto m = moveTree(s.tree.text(), "origin", "main", commit.text());
    assert(m.ok, m.why());
    assert(!m.thrown, "nothing conflicted, so the work was kept");
    sh("git -C '", s.tree.text(), "' merge-base --is-ancestor ", commit.text(), " HEAD");
    sh("test -f '", s.tree.text(), "/notes.txt'");
    sh("rm -rf '", s.root.text(), "'");
}

unittest {
    // "maybe i just want it to throw the whole tree away and reinit"
    // "or that can be a fallback"
    // When the stash, pull or unstash fails, the tree is set to the push and cleaned; when that fails too, the performance halts where it stands.
    import ritual : moveTree;
    auto s = stage();
    sh("printf 'mine\\n' > '", s.tree.text(), "/steps.txt'");
    auto commit = push(s, "two");
    auto m = moveTree(s.tree.text(), "origin", "main", commit.text());
    assert(m.ok, m.why());
    assert(m.thrown, "the unstash conflicted, so the tree was thrown away");
    assert(m.why().length > 0, "and it says what git refused");
    assert(gitOut(s.tree.text(), "rev-parse HEAD").text() == commit.text());
    assert(gitOut(s.tree.text(), "status --porcelain").text() == "");
    sh("rm -rf '", s.root.text(), "'");
}

unittest {
    // A tree that is gone cannot be moved, kept or thrown away.
    import ritual : moveTree;
    auto m = moveTree("/nonexistent/ground-regoto", "origin", "main", "0000000");
    assert(!m.ok);
    assert(m.why().length > 0);
}

private Position walking(const(char)[] tree) {
    auto p = start("stepcounter", 4);
    p.id = "stepcounter-1000";
    p.repo = "/alice/smartwatchapp";
    p.rites = "STEP1,STEP2,STEP3,END";
    p.worktree = tree;
    p.agentSession = "agent-1";
    p.parent = "parent-1";
    p.current = 3;
    p.gotos = 2; p.evals = 4;
    return p;
}
import ritual : Position;

unittest {
    // "because the new one should be the one that is the change"
    // Two pushes while one rite runs: the newer is the one that waits.
    import ritual : landOn, landingOf;
    auto s = stage();
    auto db = memDb();
    assert(writePosition(db, walking(s.tree.text())));
    push(s, "two");
    cast(void) landOn(db, parsePbt(withRegoto), "stepcounter", "", s.pusher.text(), "pusher-1");
    auto newer = push(s, "three");
    cast(void) landOn(db, parsePbt(withRegoto), "stepcounter", "", s.pusher.text(), "pusher-1");
    assert(landingOf(db, "stepcounter-1000") == newer.text());
    sqlite3_close(db);
    sh("rm -rf '", s.root.text(), "'");
}

unittest {
    // "But regoto should wait for the existing rite to finish and then resolve"
    // The fire leaves the push waiting on the row. The rite in flight runs on in
    // a tree nobody moves, and the walk stays where it is.
    import ritual : landOn, byPerformanceId, readPush, landingOf;
    auto s = stage();
    auto db = memDb();
    assert(writePosition(db, walking(s.tree.text())));
    auto before = gitOut(s.tree.text(), "rev-parse HEAD");
    auto commit = push(s, "two");

    auto said = landOn(db, parsePbt(withRegoto), "stepcounter", "", s.pusher.text(), "pusher-1",
                       "git push", "pushed two");
    assert(said == "stepcounter-1000 goes to STEP2 when the rite it is on ends", said);
    assert(landingOf(db, "stepcounter-1000") == commit.text());
    auto push = readPush(db, "stepcounter-1000");
    assert(push.output() == "pushed two" && push.input() == "git push");
    auto got = byPerformanceId(db, "stepcounter-1000");
    assert(got.p.current == 3 && got.p.gotos == 2, "the walk is not moved under the rite");
    assert(gitOut(s.tree.text(), "rev-parse HEAD").text() == before.text(), "the tree is not moved under the rite");
    sqlite3_close(db);
    sh("rm -rf '", s.root.text(), "'");
}

unittest {
    // Once the rite has ended the driver resolves it: the tree onto the push,
    // the walk to the regoto rite, and the agent and the parent told.
    import ritual : landOn, resolveLanding, byPerformanceId, landingOf;
    auto s = stage();
    auto db = memDb();
    assert(writePosition(db, walking(s.tree.text())));
    auto commit = push(s, "two");
    cast(void) landOn(db, parsePbt(withRegoto), "stepcounter", "", s.pusher.text(), "pusher-1");

    auto said = resolveLanding(db, parsePbt(withRegoto), "stepcounter-1000");
    Buf want;
    want.put("stepcounter-1000 went to STEP2 at ");
    want.put(commit.text()[0 .. 7]);
    want.put(", the work in its tree kept");
    assert(said == want.text(), said);
    auto got = byPerformanceId(db, "stepcounter-1000");
    assert(got.p.current == 1 && got.p.gotos == 0 && got.p.evals == 0);
    assert(got.p.state == RitualState.Live);
    assert(gitOut(s.tree.text(), "rev-parse HEAD").text() == commit.text());
    assert(landingOf(db, "stepcounter-1000").length == 0, "landed once");
    assert(resolveLanding(db, parsePbt(withRegoto), "stepcounter-1000") is null, "nothing waits");

    // TODO open: a note's id is its session and key, so a second regoto note to the same agent replaces the first before it is read.
    import immediate : readImmediateMessage;
    assert(readImmediateMessage(db, "/tmp", "agent-1").message == want.text());
    assert(readImmediateMessage(db, "/tmp", "parent-1").message == want.text());
    sqlite3_close(db);
    sh("rm -rf '", s.root.text(), "'");
}

unittest {
    // The rite in flight ended the walk while the push waited. The push still
    // applies: the walk is brought back to the regoto rite.
    import ritual : landOn, resolveLanding, byPerformanceId;
    auto s = stage();
    auto db = memDb();
    assert(writePosition(db, walking(s.tree.text())));
    push(s, "two");
    cast(void) landOn(db, parsePbt(withRegoto), "stepcounter", "", s.pusher.text(), "pusher-1");
    auto ended = byPerformanceId(db, "stepcounter-1000").p;
    ended.state = RitualState.Done;
    assert(writePosition(db, ended));

    assert(resolveLanding(db, parsePbt(withRegoto), "stepcounter-1000") !is null);
    auto got = byPerformanceId(db, "stepcounter-1000");
    assert(got.p.state == RitualState.Live && got.p.current == 1);
    sqlite3_close(db);
    sh("rm -rf '", s.root.text(), "'");
}

unittest {
    // An abort is the operator's, and a push does not undo it.
    import ritual : landOn, resolveLanding, byPerformanceId, landingOf;
    auto s = stage();
    auto db = memDb();
    assert(writePosition(db, walking(s.tree.text())));
    push(s, "two");
    cast(void) landOn(db, parsePbt(withRegoto), "stepcounter", "", s.pusher.text(), "pusher-1");
    auto aborted = byPerformanceId(db, "stepcounter-1000").p;
    aborted.state = RitualState.Aborted;
    assert(writePosition(db, aborted));

    auto said = resolveLanding(db, parsePbt(withRegoto), "stepcounter-1000");
    assert(said == "stepcounter-1000 was aborted, so the push that waited on it did not land", said);
    assert(byPerformanceId(db, "stepcounter-1000").p.state == RitualState.Aborted);
    assert(landingOf(db, "stepcounter-1000").length == 0);
    sqlite3_close(db);
    sh("rm -rf '", s.root.text(), "'");
}

unittest {
    // A tree that cannot be moved halts the performance where it stands.
    import ritual : landOn, resolveLanding, byPerformanceId;
    auto s = stage();
    auto db = memDb();
    assert(writePosition(db, walking("/nonexistent/ground-regoto")));
    push(s, "two");
    cast(void) landOn(db, parsePbt(withRegoto), "stepcounter", "", s.pusher.text(), "parent-1");

    auto said = resolveLanding(db, parsePbt(withRegoto), "stepcounter-1000");
    assert(said.length > 0);
    auto got = byPerformanceId(db, "stepcounter-1000");
    assert(got.valid && got.p.state == RitualState.Halted && got.p.current == 3);
    import immediate : readImmediateMessage;
    assert(readImmediateMessage(db, "/tmp", "agent-1").message == said);
    assert(readImmediateMessage(db, "/tmp", "parent-1").message == said);
    sqlite3_close(db);
    sh("rm -rf '", s.root.text(), "'");
}

// The driver resolves a waiting push between rites, and a fire kills nothing.
private enum driveSource = import("source/ritual/drive.d");
private enum regotoSource = import("source/ritual/regoto.d");
private bool has(const(char)[] hay, const(char)[] needle) {
    foreach (i; 0 .. hay.length < needle.length ? 0 : hay.length - needle.length + 1)
        if (hay[i .. i + needle.length] == needle) return true;
    return false;
}
static assert(has(driveSource, "resolveLanding("), "the driver lands a waiting push between rites");
static assert(!has(regotoSource, "kill("), "a fire does not kill the rite in flight");

// "for the live test you may create a ritual with W1, W2, W3 each taking 10 sec to complete"
// "fires on push"
// "like the deploy ritual"
// "and happens for ground repo"
// "THE REGOTO SHOULD BE W2"
// "W4 IS ANOTHER 10 SEC"
enum regotoWalk = `
project {
  path: "/teranos/ground"

  control {
    name: "regoto-walk"
    event: "PostToolUse"
    cmd: "git push"

    ritual {
      system: "You came into existence because of a git push to teranos/ground. You do nothing to the tree; each turn, say which rite the walk is on."
      regoto: W2
      tree: "checkout"

      walk
    }
  }
}

rites walk {
  W1 {
    run: "sleep 10"
  }
  W2 {
    run: "sleep 10"
  }
  W3 {
    run: "sleep 10"
  }
  W4 {
    run: "sleep 10"
  }
}
`;
static assert(parsePbt(regotoWalk).rituals[0].name == "regoto-walk");
static assert(parsePbt(regotoWalk).rituals[0].regoto == "W2");
static assert(parsePbt(regotoWalk).rituals[0].tree == "checkout");
static assert(validateRituals(parsePbt(regotoWalk)).text() == "");
