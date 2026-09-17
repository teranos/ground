module reap_test;

// "HOW IS THERE NOT A REAL NATIVE TRUE WAY TO KILL THE BG SESSION"

import ritual.run : reapScript;

private enum driveSource = import("source/ritual/drive.d");
private enum commandSource = import("source/ritual/command.d");

private bool contains(const(char)[] hay, const(char)[] needle) {
    if (needle.length > hay.length) return false;
    foreach (i; 0 .. hay.length - needle.length + 1) {
        bool hit = true;
        foreach (j; 0 .. needle.length)
            if (hay[i + j] != needle[j]) { hit = false; break; }
        if (hit) return true;
    }
    return false;
}

enum r = reapScript("e5f42580-1a2b-4c3d-9e8f-0123456789ab");

// Proven: `claude stop 422bddec` answered `stopped 422bddec` and kept the tree.
static assert(contains(r.text(), "claude stop"),
    "the documented ending, not a signal");

// `pgrep -f 'claude -w'` returned 0 at every sample through a whole
// performance, live and done. It has never matched a process.
static assert(!contains(r.text(), "claude -w"),
    "the old handle is not in the agent's command line");
static assert(!contains(r.text(), "pkill"),
    "a signal drops the agent mid-turn and races whatever restarts it");

// The agent ground started is the agent ground ends. Selecting on the tree
// stopped every background session whose cwd matched, and a ritual that names
// no tree performs in a checkout a person is working in.
static assert(!contains(r.text(), ".cwd=="),
    "a directory is not an identity");
static assert(contains(r.text(), "'e5f42580-1a2b-4c3d-9e8f-0123456789ab'"));

// Nothing to reap without one, and an empty pattern would match everything.
static assert(reapScript("").text().length == 0);

// "also, agents dont seem to die afetr ritual ends"
// Measured 2026-09-17: every performance of the day ended with `session` empty,
// so the reap above had nothing to name and was skipped without a word. The
// agent is a spare the claude daemon warmed before the ritual existed, and it
// carries the daemon's environment: the 2goto agent read
// GROUND_PERFORMANCE=q-deploy-1789643160, a performance from hours before.
import ritual.run : agentIdFrom, reapTarget;
import ritual.position : Position;

// What `claude --bg` prints is the one account of who was started that comes
// from the start itself.
enum printed = "backgrounded \xC2\xB7 7a5399f5\n"
    ~ "  claude agents             list sessions\n"
    ~ "  claude attach 7a5399f5    open in this terminal\n"
    ~ "  claude stop 7a5399f5      stop this session\n";
static assert(agentIdFrom(printed) == "7a5399f5");

// Anything else names nobody, and a guess would stop a stranger.
static assert(agentIdFrom("") == "");
static assert(agentIdFrom("error: daemon not running\n") == "");
static assert(agentIdFrom("backgrounded") == "");
static assert(agentIdFrom("backgrounded \xC2\xB7 \n") == "");

// The id the start printed is what `claude stop` was proven on, so it is what
// the reap names. The session is the fallback for a row bound the old way.
private Position carrying(const(char)[] agent, const(char)[] session) {
    Position p;
    p.agent = agent;
    p.agentSession = session;
    return p;
}
static assert(reapTarget(carrying("7a5399f5", "7a5399f5-0d25-4a97-a62a-93fefe1324f8")) == "7a5399f5");
static assert(reapTarget(carrying("", "e5f42580-1a2b")) == "e5f42580-1a2b");
static assert(reapTarget(carrying("", "")) == "");

// One reap, reached by every ending: the driver's, the abort's, and the bind
// that arrives after a walk is already over. An ending with nobody to stop is
// said rather than skipped.
private enum runSource = import("source/ritual/run.d");
static assert(contains(runSource, "reapScript(reapTarget(p))"));
static assert(contains(runSource, `"ritual.reap.unbound"`));
static assert(contains(driveSource, "reapNow(found.p,"));
static assert(contains(commandSource, "reapNow(p,"));
static assert(contains(commandSource, "reapNow(found.p,"));

// The start hands what it printed to ground. An environment variable reaches
// the daemon's spare from the daemon, not from this script.
import ritual.run : spawnScript;
enum spawned = spawnScript("/r", "p-1", "p-1", "go");
static assert(contains(spawned.text(), "| ground bind 'p-1'\n"));
static assert(!contains(spawned.text(), "GROUND_PERFORMANCE"));
