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
    char[4096] buf = 0;
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
// The one thing gh is still asked for, and only because it holds the
// credential. A missing token says so rather than aborting on `set -u`.
private void putToken(ref DispatchScript s) {
    s.put("tok=''\n");
    s.put("if env | grep -q '^GH_TOKEN='; then tok=$(env | grep -m1 '^GH_TOKEN=' | cut -d= -f2-); fi\n");
    s.put("if [ -z \"$tok\" ] && env | grep -q '^GITHUB_TOKEN='; then tok=$(env | grep -m1 '^GITHUB_TOKEN=' | cut -d= -f2-); fi\n");
    s.put("if [ -z \"$tok\" ] && command -v gh > /dev/null 2>&1; then tok=$(gh auth token); fi\n");
    s.put("if [ -z \"$tok\" ]; then\n");
    s.put("  printf 'no github token: set GH_TOKEN or run gh auth login\\n'\n");
    s.put("  exit ");
    s.putNum(RITE_UNREACHED);
    s.put("\nfi\n");
}

private void putThrottle(ref DispatchScript s) {
    s.put("gh_throttle() {\n");
    s.put("  rl=$(curl -sS -m 20 -H \"Authorization: Bearer $tok\" ");
    s.put("https://api.github.com/rate_limit 2>&1) || {\n");
    s.put("    printf 'could not read the quota: %s\\n' \"$rl\"\n");
    s.put("    exit ");
    s.putNum(RITE_UNREACHED);
    s.put("\n  }\n");

    // used and limit out of the JSON without jq: the two numbers are the whole
    // of what a throttle needs, and a dependency to read them is a dependency.
    s.put("  used=$(printf '%s' \"$rl\" | tr ',' '\\n' | grep -m1 '\"used\"' | tr -cd '0-9')\n");
    s.put("  lim=$(printf '%s' \"$rl\" | tr ',' '\\n' | grep -m1 '\"limit\"' | tr -cd '0-9')\n");
    s.put("  if [ -z \"$used\" ] || [ -z \"$lim\" ] || [ \"$lim\" = 0 ]; then\n");
    s.put("    printf 'rate_limit answered %s\\n' \"$rl\"\n");
    s.put("    exit ");
    s.putNum(RITE_UNREACHED);
    s.put("\n  fi\n");
    s.put("  pct=$(( used * 100 / lim ))\n");

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

// A dispatch github could not answer is retried on a widening gap: one at N,
// two at 2N, three at 3N, four at 4N. Ten attempts, the last at 30N.
enum BACKOFF_SEC = 5;
enum BACKOFF_ATTEMPTS = 10;

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

    s.putToken();
    s.putThrottle();

    // The branch is stated, not resolved: gh asked graphql for it first, a
    // round-trip ground never needed to make. Read through env rather than
    // $GROUND_REF — under `set -u` an unset variable aborts.
    s.put("ref=master\n");
    s.put("if env | grep -q '^GROUND_REF='; then\n");
    s.put("  ref=$(env | grep -m1 '^GROUND_REF=' | cut -d= -f2-)\n");
    s.put("fi\n");

    // The run has to carry a name ground chose, or newest-first is a guess.
    s.put("fields=''\n");
    if (token.length > 0) {
        s.put("fields='\"ground\":\"");
        s.put(token);
        s.put("\"'\n");
    }

    // Each line the fragment prints is one input. cut rather than parameter
    // expansion, because a `${` in a rite is refused before it runs.
    if (inputs.length > 0) {
        s.put("while IFS= read -r kv; do\n");
        s.put("  [ -n \"$kv\" ] || continue\n");
        s.put("  k=$(printf '%s' \"$kv\" | cut -d= -f1)\n");
        s.put("  v=$(printf '%s' \"$kv\" | cut -d= -f2-)\n");
        s.put("  if [ -n \"$fields\" ]; then fields=\"$fields,\"; fi\n");
        s.put("  fields=\"$fields\\\"$k\\\":\\\"$v\\\"\"\n");
        s.put("done <<< \"$(");
        s.put(inputs);
        s.put(")\"\n");
    }
    s.put("json=\"{\\\"ref\\\":\\\"$ref\\\",\\\"inputs\\\":{$fields}}\"\n");

    // "1 retry in N seconds / 2 consecutive retries in N+N / 3 consecutive
    // retries in N+N+N / 4 consecutive retries in N+N+N+N" — ten attempts.
    s.put("n=");
    s.putNum(BACKOFF_SEC);
    s.put("\nattempt=0\n");
    s.put("while : ; do\n");
    s.put("  gh_throttle\n");

    // curl reports the status as a number rather than as text to match on, and
    // its exit codes say which way it failed: 7 connect, 28 timeout, 35 TLS.
    s.put("  code=$(curl -sS -m 30 -o /tmp/ground-dispatch.$$ -w '%{http_code}' ");
    s.put("-X POST -H \"Authorization: Bearer $tok\" ");
    s.put("-H 'Accept: application/vnd.github+json' -d \"$json\" ");
    s.put("\"https://api.github.com/repos/$repo/actions/workflows/$flow/dispatches\")\n");
    s.put("  rc=$?\n");
    s.put("  body=$(cat /tmp/ground-dispatch.$$ 2>/dev/null); rm -f /tmp/ground-dispatch.$$\n");
    s.put("  if [ \"$rc\" = 0 ] && [ \"$code\" = 204 ]; then exit 0; fi\n");

    // A status github did answer, that is not 5xx or 429, is a refusal rather
    // than an outage. Asking it ten times would get the same refusal ten times.
    s.put("  if [ \"$rc\" = 0 ]; then\n");
    s.put("    case \"$code\" in\n");
    s.put("      5*|429) : ;;\n");
    s.put("      *) printf 'github answered %s: %s\\n' \"$code\" \"$body\"; exit 1 ;;\n");
    s.put("    esac\n");
    s.put("    printf 'github answered %s, retrying\\n' \"$code\"\n");
    s.put("  else\n");
    s.put("    printf 'curl could not reach github (exit %s), retrying\\n' \"$rc\"\n");
    s.put("  fi\n");

    s.put("  attempt=$((attempt+1))\n");
    s.put("  if [ \"$attempt\" -ge ");
    s.putNum(BACKOFF_ATTEMPTS);
    s.put(" ]; then\n");
    s.put("    printf 'github did not accept the dispatch in %s attempts\\n' \"$attempt\"\n");
    s.put("    exit ");
    s.putNum(RITE_UNREACHED);
    s.put("\n  fi\n");

    // 1 gap at N, 2 at 2N, 3 at 3N, 4 at 4N.
    s.put("  case \"$attempt\" in\n");
    s.put("    1) m=1 ;;\n");
    s.put("    2|3) m=2 ;;\n");
    s.put("    4|5|6) m=3 ;;\n");
    s.put("    *) m=4 ;;\n");
    s.put("  esac\n");
    s.put("  sleep $((n*m))\n");
    s.put("done\n");
    return s;
}

