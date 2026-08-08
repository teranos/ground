module mic;

// "the object that signifies who is speaking into the receiver is called a mic"
// "there can only be 1 mic per ritual performance"
// "something is always holding the mic"

// "PARENT: HUMAN / HOSTLLM"
// "CHILD : RITUAL / AGENTLLM"
// "it is the error code that is holding the mic"
enum Mic {
    Ground,
    Agent,
    Ci,
    Human,
    Error,
}

immutable string[5] MIC_WORD = ["ground", "agent", "ci", "human", "error"];

string micWord(Mic m) { return MIC_WORD[cast(size_t) m]; }

struct MicRead { bool valid; Mic who; }

MicRead micFromWord(const(char)[] word) {
    foreach (i, w; MIC_WORD)
        if (word == w) return MicRead(true, cast(Mic) i);
    return MicRead(false);
}

long wordsHash(const(char)[] s) {
    if (s.length == 0) return 0;
    long h = 0x811c9dc5;
    foreach (c; s) {
        h ^= cast(long) c;
        h *= 0x01000193;
        h &= 0x7fff_ffff_ffff_ffff;
    }
    return h == 0 ? 1 : h;
}

bool freshWords(long said, long previous) {
    return said != 0 && said != previous;
}

// "ground, or the rite should have no reason to keep holding the mic for
// longer than 2s"
enum GROUND_BOUND = 2;

// "i want to know who is holding the mic and if holding it is legitimate, or
// just blocking the entire performance"
long micBound(Mic who, long ciExpected, long agentExpected) {
    final switch (who) {
    case Mic.Ground: return GROUND_BOUND;
    case Mic.Ci:     return ciExpected;
    case Mic.Agent:  return agentExpected;
    case Mic.Human:  return 0;
    // The API says when it will be over, not ground. Until `retry-after` is
    // read, an outage has no bound and cannot be called late.
    case Mic.Error:  return 0;
    }
}

// "and ci keeps holding the mic in this case"
Mic holder(int wait) {
    return wait > 0 ? Mic.Ci : Mic.Ground;
}

bool blocking(Mic who, long heldFor, long ciExpected, long agentExpected) {
    auto bound = micBound(who, ciExpected, agentExpected);
    if (bound <= 0) return false;
    return heldFor > bound;
}
