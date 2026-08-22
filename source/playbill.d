module playbill;

// What could be performed where you are standing, and what starts it. A session
// met the rituals of its own project only when one interrupted, so a halted rite
// arrived as a word from a tool the session had never run.

import ritual.position : MAX_RITES;

// A ritual named by several controls is several cues, and every one of them is
// something a session would otherwise not be told. The assert is deliberate:
// dropping one silently is the failure this exists to end.
enum MAX_CUES = 32;

struct Cue {
    string ritual;
    string event;
    // Carried whole so scopeMatches decides, negations included. The rule that
    // says whether the ritual fires is the rule that says whether it is named.
    string[8] paths;
    ubyte pathCount;
    string[8] cmds;
    ubyte cmdCount;
    // In walk order, which is the order a halt line counts to.
    string[MAX_RITES] rites;
    size_t riteCount;
}

struct Bill {
    Cue[MAX_CUES] cues;
    size_t len;
}

// CTFE. Every control that names a ritual, paired with the scope that starts it.
Bill cuesOf(PR)(const PR parsed) {
    import ritual.resolve : flatten;

    Bill b;
    foreach (si; 0 .. parsed.scopeCount) {
        auto sc = parsed.scopes[si];
        foreach (ci; sc.controlStart .. sc.controlEnd) {
            auto name = parsed.ctrlPool[ci].ritual;
            if (name.length == 0) continue;

            assert(b.len < MAX_CUES, "cue overflow — bump MAX_CUES");

            Cue cue;
            cue.ritual = name;
            cue.event = sc.event;
            cue.paths = sc.paths;
            cue.pathCount = sc.pathCount;
            cue.cmds = sc.cmds;
            cue.cmdCount = sc.cmdCount;

            foreach (ri; 0 .. parsed.ritualCount) {
                if (parsed.rituals[ri].name != name) continue;
                auto flat = flatten(parsed, ri);
                foreach (k; 0 .. flat.count) cue.rites[k] = flat.rites[k].name;
                cue.riteCount = flat.count;
                break;
            }

            b.cues[b.len] = cue;
            b.len++;
        }
    }
    return b;
}

// One cue's sentence, with nothing joining it. What separates two of them is
// the caller's, because a hook's context and a hook's stderr do not agree.
size_t cueInto(const ref Cue cue, char[] dest) {
    size_t o = 0;
    void put(const(char)[] s) {
        foreach (c; s) if (o < dest.length) dest[o++] = c;
    }

    put(cue.ritual);
    put(" performs here on ");

    // A scope naming no command is started by the event alone, and empty
    // backticks would say a command exists that nothing wrote.
    foreach (i; 0 .. cue.cmdCount) {
        if (i > 0) put(", ");
        put("`");
        put(cue.cmds[i]);
        put("`");
        put(" ");
    }

    if (cue.cmdCount > 0) put("(");
    put(cue.event);
    if (cue.cmdCount > 0) put(")");

    if (cue.riteCount > 0) {
        put(": ");
        foreach (i; 0 .. cue.riteCount) {
            if (i > 0) put(" > ");
            put(cue.rites[i]);
        }
    }
    return o;
}

// One sentence per cue that fires here, joined the way a session's context is.
size_t billInto(const(Cue)[] cues, const(char)[] cwd, char[] dest) {
    import hooks : scopeMatches;

    size_t o = 0;
    foreach (ref cue; cues) {
        if (!scopeMatches(cue, cwd)) continue;
        if (o > 0) {
            foreach (c; " | ") if (o < dest.length) dest[o++] = c;
        }
        o += cueInto(cue, dest[o .. $]);
    }
    return o;
}

// The live control set. A session is told about the rituals that are actually
// compiled in, not about a shape someone wrote down once.
import controls : allParsed;
private static immutable _bill = cuesOf(allParsed);
static immutable ritualCues = _bill.cues[0 .. _bill.len];

// One predicate for both delivery sites. Two would let the same session hear
// the same ritual twice, once per hook.
enum PLAYBILL = "GroundedPlaybill";

// Said once per session, by whichever hook is standing where it performs. A
// compaction invalidates the mark, which is right: the session has forgotten.
size_t unsaidBillInto(DB)(DB db, const(char)[] sessionId, const(char)[] cwd, char[] dest) {
    import hooks : scopeMatches;
    import db : attestationExists, attestControlFire, ZBuf;

    if (db is null || sessionId.length == 0) return 0;

    __gshared ZBuf key;
    size_t o = 0;

    foreach (ref cue; ritualCues) {
        if (!scopeMatches(cue, cwd)) continue;

        key.reset();
        key.put("playbill:");
        key.put(cue.ritual);

        if (attestationExists(db, PLAYBILL, key.slice(), sessionId)) continue;
        attestControlFire(db, PLAYBILL, key.slice(), cwd, sessionId);

        if (o > 0) {
            foreach (c; " | ") if (o < dest.length) dest[o++] = c;
        }
        o += cueInto(cue, dest[o .. $]);
    }
    return o;
}
