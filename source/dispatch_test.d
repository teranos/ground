module dispatch_test;

// "dispatch could be its own thing, its own abstraction"
// "in case i wanted to dispatch another job and track its completion with an
// agent in a ritual"

import dispatch : dispatchScript, dispatchTarget;

// `dispatch: "<owner>/<repo> <workflow>"` — two words, in the order said.
enum t = dispatchTarget("sbvh-nl/grove long-coin.yml");
static assert(t.ok);
static assert(t.repo == "sbvh-nl/grove");
static assert(t.workflow == "long-coin.yml");

// One word is not a target. Neither is three.
static assert(!dispatchTarget("long-coin.yml").ok);
static assert(!dispatchTarget("a b c").ok);
static assert(!dispatchTarget("").ok);

enum s = dispatchScript("sbvh-nl/grove long-coin.yml", "");
static assert(s.ok);
static assert(contains(s.text(), "repo='sbvh-nl/grove'\n"));
static assert(contains(s.text(), "flow='long-coin.yml'\n"));

// "you can use curl instead of gh+jq". One POST to the REST endpoint, which
// answers 204. gh resolved the default branch over graphql first, so a graphql
// outage halted a dispatch that never needed it.
static assert(contains(s.text(), "/actions/workflows/"));
static assert(contains(s.text(), "/dispatches"));
static assert(!contains(s.text(), "gh workflow run"));
static assert(!contains(s.text(), "gh api"));
static assert(!contains(s.text(), "--jq"));

// The status is a number curl hands back, not text to match on. `%{http_code}`
// is what makes a class of status catchable at all.
static assert(contains(s.text(), "%{http_code}"));
static assert(!contains(s.text(), "*'rate limit'*"));
static assert(!contains(s.text(), "*'HTTP 5'*"));

// The ref is stated rather than resolved, so no second round-trip can fail.
static assert(contains(s.text(), "\\\"ref\\\":"));

// "the dispatch happened thus we move on from the rite". It sends the job and
// ends. No run id, no status, no waiting — none of that is the rite's.
static assert(!contains(s.text(), "--json status"));
static assert(!contains(s.text(), "--json databaseId"));
static assert(!contains(s.text(), "exit 75"));

// 204 is the whole of a successful dispatch, so that is where it exits 0. An
// unhandled status falls through to 1 — a real refusal, not a retry.
static assert(contains(s.text(), "= 204 ]; then exit 0"));

// The script ends in the retry loop, not on a verdict — every way out is an
// exit inside it.
static assert(endsWith(s.text(), "done\n"));

// 5xx and 429 are github unable to answer, which is not an answer — so they
// are retried rather than halted on, and anything else github did answer is a
// refusal that exits 1 without asking again.
static assert(contains(s.text(), "5*|429) : ;;"));
static assert(contains(s.text(), "exit 1 ;;"));

// The widening gap: 1 at N, 2 at 2N, 3 at 3N, 4 at 4N, ten attempts.
static assert(contains(s.text(), "n=5\n"));
static assert(contains(s.text(), "    1) m=1 ;;\n"));
static assert(contains(s.text(), "    2|3) m=2 ;;\n"));
static assert(contains(s.text(), "    4|5|6) m=3 ;;\n"));
static assert(contains(s.text(), "    *) m=4 ;;\n"));
static assert(contains(s.text(), "sleep $((n*m))"));
static assert(contains(s.text(), "-ge 10 ]"));

// A tool that could not run has answered no question, and 125 is that. curl's
// own exit codes say which way it failed — 7 connect, 28 timeout, 35 TLS.
static assert(contains(s.text(), "exit 125"));

// Two rungs, and both say so out loud — the rite's stdout is what `to: parent`
// carries back. rate_limit is exempt from the quota, so asking is free.
static assert(contains(s.text(), "/rate_limit"));

// A probe that could not run has measured nothing, and nothing is not 0%. It
// was `|| echo 0`, so an unreachable quota read as free and the throttle waved
// through the calls the quota is spent on.
static assert(!contains(s.text(), "echo 0"));
static assert(!contains(s.text(), "pct=0"));
static assert(contains(s.text(), "could not read the quota"));
static assert(contains(s.text(), "rate_limit answered"));
static assert(contains(s.text(), "waiting 10s"));
static assert(contains(s.text(), "waiting 2s"));
static assert(contains(s.text(), "  gh_throttle\n  code=$(curl"));

// `inputs:` is the one part ground cannot know: the value is made at
// performance time, and params are literals from the pbt.
enum w = dispatchScript("sbvh-nl/q.sbvh.nl deploy.yml", "branch=$(cat BRANCH)");
static assert(w.ok);
static assert(contains(w.text(), "\\\"inputs\\\":{"));

// The fragment runs in the worktree; each line it prints becomes one input.
static assert(contains(w.text(), "done <<< \"$(branch=$(cat BRANCH))\"\n"));

// `hasUnresolved` refuses any `${` in a rite, so a dispatch that contains one
// never reaches a process, and the driver loops on it with holds=0.
static assert(!hasBraces(w.text()));
static assert(!hasBraces(s.text()));

// A target that does not split is a script ground must not run.
static assert(!dispatchScript("long-coin.yml", "").ok);

// A workflow_dispatch answers 204 with no body, so the run has to carry a name
// ground chose or newest-first is a guess.
enum k = dispatchScript("sbvh-nl/grove long-coin.yml", "", "coinflip-8ir:FLIP1");
static assert(k.ok);
static assert(contains(k.text(), "coinflip-8ir:FLIP1"));

// The token is <performance>:<rite>, so ground rebuilds it rather than reading
// it back out of the rite's stdout and into the line you read.
static assert(!contains(k.text(), "printf 'ground="));

// No token, no input — a workflow that does not declare it refuses the whole
// dispatch, and every pbt on disk predates this.
static assert(!contains(s.text(), "\"ground\":"));

// "the fucking mic is TAKEN" — the outcome has to find the agent, and the
// token is the only thing carried far enough to name the performance.
import dispatch : performanceOf;
static assert(performanceOf("coinflip-1786888445:FLIP1") == "coinflip-1786888445");
static assert(performanceOf("q-deploy-1786845074:WEB") == "q-deploy-1786845074");

// A token is <performance>:<rite>. Without the rite it names no performance.
static assert(performanceOf("coinflip-1786888445") == "");
static assert(performanceOf("") == "");

private bool hasBraces(const(char)[] c) {
    foreach (i; 0 .. c.length)
        if (i + 1 < c.length && c[i] == '$' && c[i + 1] == '{') return true;
    return false;
}

private bool endsWith(const(char)[] hay, const(char)[] tail) {
    if (tail.length > hay.length) return false;
    return hay[$ - tail.length .. $] == tail;
}

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
