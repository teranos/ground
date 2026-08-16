module dispatch;

import worktree : addQuoted;
import rite : RITE_UNREACHED;

// Where a job lives and which job it is. Two words, in the order said.
struct Target {
    const(char)[] repo;
    const(char)[] workflow;
    bool ok;
}

Target dispatchTarget(const(char)[] s) {
    Target t;
    size_t sp;
    bool found;
    foreach (i, c; s) {
        if (c != ' ') continue;
        if (found) return t;
        sp = i;
        found = true;
    }
    if (!found) return t;
    t.repo = s[0 .. sp];
    t.workflow = s[sp + 1 .. $];
    if (t.repo.length == 0 || t.workflow.length == 0) return t;
    t.ok = true;
    return t;
}

// The performance a token belongs to. It is what carries far enough to find
// the agent when the run concludes, long after the rite is behind the walk.
const(char)[] performanceOf(const(char)[] token) {
    size_t cut;
    bool found;
    foreach (i, c; token) {
        if (c != ':') continue;
        cut = i;
        found = true;
    }
    if (!found || cut == 0) return "";
    return token[0 .. cut];
}

struct DispatchScript {
    char[2048] buf = 0;
    size_t len;
    bool ok = true;
    const(char)[] text() const return { return ok ? buf[0 .. len] : null; }
}

private void put(ref DispatchScript s, const(char)[] t) {
    foreach (c; t) { if (s.len < s.buf.length - 1) s.buf[s.len++] = c; else s.ok = false; }
}

private void putQ(ref DispatchScript s, const(char)[] t) {
    if (!addQuoted(s.buf[], s.len, t)) s.ok = false;
}

// "+70% GLOBALQUOTA USE MEANS ADDING 10s BEFORE EVERY gh TOOL CALL". The
// rate_limit endpoint is itself exempt, so asking costs nothing.
private void putThrottle(ref DispatchScript s) {
    s.put("gh_throttle() {\n");
    s.put("  pct=$(gh api rate_limit --jq '(.rate.used * 100 / .rate.limit) | floor' 2>/dev/null || echo 0)\n");
    s.put("  case \"$pct\" in ''|*[!0-9]*) pct=0 ;; esac\n");
    s.put("  if [ \"$pct\" -ge ");
    s.putNum(QUOTA_HIGH_PCT);
    s.put(" ]; then\n");
    s.put("    printf 'github quota at %s%%, waiting ");
    s.putNum(QUOTA_HIGH_SEC);
    s.put("s\\n' \"$pct\"\n");
    s.put("    sleep ");
    s.putNum(QUOTA_HIGH_SEC);
    s.put("\n  elif [ \"$pct\" -ge ");
    s.putNum(QUOTA_LOW_PCT);
    s.put(" ]; then\n");
    s.put("    printf 'github quota at %s%%, waiting ");
    s.putNum(QUOTA_LOW_SEC);
    s.put("s\\n' \"$pct\"\n");
    s.put("    sleep ");
    s.putNum(QUOTA_LOW_SEC);
    s.put("\n  fi\n");
    s.put("  return 0\n");
    s.put("}\n");
}

private void putNum(ref DispatchScript s, int v) {
    char[12] d = 0;
    size_t n;
    if (v == 0) d[n++] = '0';
    while (v > 0) { d[n++] = cast(char)('0' + v % 10); v /= 10; }
    foreach (i; 0 .. n) s.put(d[n - 1 - i .. n - i]);
}

// A run still going is what Hold already means, so the rite answers and is
// asked again. A rite that blocks writes nothing for the length of a CI run.
enum DISPATCH_HOLD = 75;

// Ground spent a whole 5000-request hour on retries in one afternoon. Past a
// share of the quota, every gh call waits first. Two rungs, set low on purpose
// so the mechanism is seen working; once it is, they move to 60 and 90.
enum QUOTA_LOW_PCT  = 10;
enum QUOTA_LOW_SEC  = 2;
enum QUOTA_HIGH_PCT = 70;
enum QUOTA_HIGH_SEC = 10;

// The whole of what a pbt used to carry in bash. A workflow_dispatch run lands
// on the default branch rather than the commit that triggered it, so there is
// no sha to find it by — the id is whatever appeared that was not there before.
DispatchScript dispatchScript(const(char)[] target, const(char)[] inputs,
                              const(char)[] token = "") {
    DispatchScript s;
    auto t = dispatchTarget(target);
    if (!t.ok) {
        s.ok = false;
        return s;
    }

    s.put("repo=");
    s.putQ(t.repo);
    s.put("\nflow=");
    s.putQ(t.workflow);
    s.put("\n");

    // A tool that could not run has not answered a question. 125 is the code
    // for that, and a rite may not declare it as a catch, so it always halts.
    s.put("halt_if_unreachable() {\n");
    s.put("  case \"$1\" in\n");
    s.put("    *'rate limit'*|*'HTTP 403'*|*'HTTP 5'*|*'connect'*) return 0 ;;\n");
    s.put("  esac\n");
    s.put("  return 1\n");
    s.put("}\n");

    s.putThrottle();

    // The run has to carry a name ground chose, or newest-first is a guess.
    if (token.length > 0) {
        s.put("set -- -f ground=");
        s.putQ(token);
        s.put("\n");
    } else {
        s.put("set --\n");
    }

    // The fragment is the one part ground cannot know: the value is made at
    // performance time, and params are literals from the pbt.
    if (inputs.length > 0) {
        // Positional parameters, not an array: `hasUnresolved` refuses any `${`
        // in a rite, and an array expansion cannot be written without one.
        s.put("while IFS= read -r kv; do\n");
        s.put("  if [ -n \"$kv\" ]; then set -- \"$@\" -f \"$kv\"; fi\n");
        s.put("done <<< \"$(");
        s.put(inputs);
        s.put(")\"\n");
    }
    s.put("gh_throttle\n");
    s.put("if ! out=$(gh workflow run \"$flow\" -R \"$repo\" \"$@\" 2>&1); then\n");
    s.put("  printf '%s\\n' \"$out\"\n");
    s.put("  if halt_if_unreachable \"$out\"; then exit ");
    s.putNum(RITE_UNREACHED);
    s.put("; fi\n  exit 1\nfi\n");

    // The rite sent the job. That is the whole of it.
    s.put("exit 0\n");
    return s;
}

