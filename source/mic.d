module mic;

// Who is speaking into the receivers.
// "there can only be 1 mic per ritual performance" / "something is always
// holding the mic"

enum Mic {
    Ground,  // a rite is being evaluated
    Agent,   // the model carrying the performance
    Ci,      // a run somewhere else, whose completion hands it on
    Human,   // the operator, who is never on a clock
}

// Stored as a word so the row reads without a decoder, the way `state` does.
immutable string[4] MIC_WORD = ["ground", "agent", "ci", "human"];

string micWord(Mic m) { return MIC_WORD[cast(size_t) m]; }

// A word this build cannot read is not silently Ground — that would say the
// mic is with a rite when nobody knows where it is.
struct MicRead { bool valid; Mic who; }

MicRead micFromWord(const(char)[] word) {
    foreach (i, w; MIC_WORD)
        if (word == w) return MicRead(true, cast(Mic) i);
    return MicRead(false);
}

// Seconds a holder may have it before holding is the problem rather than the
// work. Zero is unbounded, and only the human gets that for free.
enum GROUND_BOUND = 2;

// CI's bound is not a constant: `adaptive.d` keeps p50/p90 of the last twenty
// runs per repo and branch, so a fifteen-second job is legitimate at fifteen.
long micBound(Mic who, long ciExpected, long agentExpected) {
    final switch (who) {
    case Mic.Ground: return GROUND_BOUND;
    case Mic.Ci:     return ciExpected;
    case Mic.Agent:  return agentExpected;
    case Mic.Human:  return 0;
    }
}

// Held longer than the holder should need. Not a flag anyone sets, so there is
// nothing to forget to clear.
bool blocking(Mic who, long heldFor, long ciExpected, long agentExpected) {
    auto bound = micBound(who, ciExpected, agentExpected);
    if (bound <= 0) return false;
    return heldFor > bound;
}
