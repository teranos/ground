module phases;

// Phases: where a hook's time went, as its timing row remembers it: key=NNus pairs, the total, and the exit taken.

// "perhaps its better to focus on improving the instrument?"
// A row said how long the process took and how long the handler took, and
// nothing about the difference. The row now begins where the process does.

void putNum(S)(ref S sink, long v) {
    if (v < 0) v = 0;
    char[20] digits = 0;
    size_t n = 0;
    if (v == 0) digits[n++] = '0';
    while (v > 0) { digits[n++] = cast(char)('0' + v % 10); v /= 10; }
    foreach_reverse (i; 0 .. n) sink.put(digits[i .. i + 1]);
}

void putUs(S)(ref S sink, long v) {
    putNum(sink, v);
    sink.put("us");
}

// Milliseconds to one decimal, since a mean of a phase is read against a
// budget written in milliseconds.
void putMs(S)(ref S sink, long us) {
    auto tenths = (us < 0 ? 0 : us) / 100;
    putNum(sink, tenths / 10);
    sink.put(".");
    putNum(sink, tenths % 10);
    sink.put("ms");
}

// Where the event row's write to ground.db went, step by step. lock is the
// time the busy handler slept for another writer, and lies inside write.
struct Store {
    long stdinUs;
    long openUs;
    long writeUs;
    long lockUs;
    long closeUs;
    long total() const { return stdinUs + openUs + writeUs + closeUs; }
}

// What the handler cannot see, then whatever it measured.
void outerPhases(S)(ref S sink, Store s, long handlerUs, const(char)[] inner) {
    sink.put("stdin=");
    putUs(sink, s.stdinUs);
    sink.put(" open=");
    putUs(sink, s.openUs);
    sink.put(" write=");
    putUs(sink, s.writeUs);
    sink.put(" lock=");
    putUs(sink, s.lockUs);
    sink.put(" close=");
    putUs(sink, s.closeUs);
    sink.put(" handler=");
    putUs(sink, handlerUs);
    if (inner.length > 0) {
        sink.put(" ");
        sink.put(inner);
    }
}

// Stamps taken along one path through a handler, emitted as the time from
// each to the one before it. A zero stamp is a phase this exit never entered.
void phaseChain(S)(ref S sink, long t0, const(string)[] keys, const(long)[] stamps,
                   long tEnd, const(char)[] exitLabel) {
    long prev = t0;
    foreach (i, k; keys) {
        if (i >= stamps.length || stamps[i] == 0) continue;
        sink.put(k);
        sink.put("=");
        putUs(sink, stamps[i] - prev);
        sink.put(" ");
        prev = stamps[i];
    }
    sink.put("total=");
    putUs(sink, tEnd - t0);
    sink.put(" exit=");
    sink.put(exitLabel);
}

struct PhaseEntry {
    const(char)[] key;
    long val;
    bool isSub; // indented sub-phase
}

// Parse phases into flat array of entries (including sub-phases).
int parsePhases(const(char)[] phases, ref PhaseEntry[32] entries) {
    if (phases.length == 0) return 0;
    int count = 0;
    size_t i = 0;
    while (i < phases.length && count < 32) {
        auto keyStart = i;
        while (i < phases.length && phases[i] != '=') i++;
        if (i >= phases.length) break;
        auto key = phases[keyStart .. i];
        i++;

        // Check for non-numeric value (e.g. exit=deny)
        if (i < phases.length && (phases[i] < '0' || phases[i] > '9')) {
            while (i < phases.length && phases[i] != ' ') i++;
            if (i < phases.length && phases[i] == ' ') i++;
            continue;
        }

        long val = 0;
        while (i < phases.length && phases[i] >= '0' && phases[i] <= '9') {
            val = val * 10 + (phases[i] - '0');
            i++;
        }
        if (i + 1 < phases.length && phases[i] == 'u' && phases[i + 1] == 's') i += 2;

        if (key != "exit" && key != "total")
            entries[count++] = PhaseEntry(key, val, false);

        // Sub-phases in parens
        if (i < phases.length && phases[i] == '(') {
            i++;
            while (i < phases.length && phases[i] != ')' && count < 32) {
                auto sk = i;
                while (i < phases.length && phases[i] != '=') i++;
                if (i >= phases.length) break;
                auto skey = phases[sk .. i];
                i++;
                long sval = 0;
                while (i < phases.length && phases[i] >= '0' && phases[i] <= '9') {
                    sval = sval * 10 + (phases[i] - '0');
                    i++;
                }
                if (i + 1 < phases.length && phases[i] == 'u' && phases[i + 1] == 's') i += 2;
                if (i < phases.length && phases[i] == ' ') i++;
                entries[count++] = PhaseEntry(skey, sval, true);
            }
            if (i < phases.length && phases[i] == ')') i++;
        }

        if (i < phases.length && phases[i] == ' ') i++;
    }
    return count;
}

// The mean of each phase over the rows added, key by key, in the order the
// keys were first met. A key a row does not carry is not a zero in that row.
struct PhaseMeans {
    enum MAX = 24;
    enum KEY = 16;
    char[KEY][MAX] keys;
    size_t[MAX] keyLen;
    long[MAX] sums;
    long[MAX] counts;
    size_t n;
    size_t rows;

    void add(const(char)[] phases) {
        rows++;
        PhaseEntry[32] e;
        auto c = parsePhases(phases, e);
        foreach (i; 0 .. c) {
            if (e[i].isSub) continue;
            auto slot = slotOf(e[i].key);
            if (slot == MAX) continue;
            sums[slot] += e[i].val;
            counts[slot]++;
        }
    }

    private size_t slotOf(const(char)[] key) {
        if (key.length == 0 || key.length > KEY) return MAX;
        foreach (i; 0 .. n)
            if (keys[i][0 .. keyLen[i]] == key) return i;
        if (n == MAX) return MAX;
        foreach (j, ch; key) keys[n][j] = ch;
        keyLen[n] = key.length;
        return n++;
    }

    void render(S)(ref S sink) {
        foreach (i; 0 .. n) {
            if (i > 0) sink.put(" ");
            sink.put(keys[i][0 .. keyLen[i]]);
            sink.put("=");
            putMs(sink, counts[i] > 0 ? sums[i] / counts[i] : 0);
        }
    }
}

// The regression notice, with the breakdown of the rows the average came from.
void regressionLine(S)(ref S sink, const(char)[] event, long avgMs, long budgetMs,
                       const(char)[] version_, ref PhaseMeans means) {
    sink.put("fyi: ground timing regression: ");
    sink.put(event);
    sink.put(" averages ");
    putNum(sink, avgMs);
    sink.put("ms (budget ");
    putNum(sink, budgetMs);
    sink.put("ms, ground ");
    foreach (i; 0 .. version_.length)
        if (version_[i] != '\n' && version_[i] != '\r') sink.put(version_[i .. i + 1]);
    sink.put(") over ");
    putNum(sink, means.rows);
    sink.put(" runs: ");
    means.render(sink);
}
