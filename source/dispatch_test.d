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

// "the dispatch happened thus we move on from the rite". It sends the job and
// ends. No run id, no status, no waiting — none of that is the rite's.
static assert(contains(s.text(), "gh workflow run \"$flow\" -R \"$repo\""));
static assert(!contains(s.text(), "--json status"));
static assert(!contains(s.text(), "--json databaseId"));
static assert(!contains(s.text(), "exit 75"));
static assert(endsWith(s.text(), "exit 0\n"));

// A tool that could not run has answered no question. 125 is that, and a rite
// may not declare it as a catch, so it halts instead of being asked again.
static assert(contains(s.text(), "halt_if_unreachable() {\n"));
static assert(contains(s.text(), "*'rate limit'*"));
static assert(contains(s.text(), "exit 125"));

// Two rungs, and both say so out loud — the rite's stdout is what `to: parent`
// carries back. rate_limit is exempt from the quota, so asking is free.
static assert(contains(s.text(), "gh api rate_limit --jq"));
static assert(contains(s.text(), "waiting 10s"));
static assert(contains(s.text(), "waiting 2s"));
static assert(contains(s.text(), "gh_throttle\nif ! out=$(gh workflow run"));

// `inputs:` is the one part ground cannot know: the value is made at
// performance time, and params are literals from the pbt.
enum w = dispatchScript("sbvh-nl/q.sbvh.nl deploy.yml", "branch=$(cat BRANCH)");
static assert(w.ok);
static assert(contains(w.text(), "set --\n"));

// The fragment runs in the worktree; each line it prints becomes one -f.
static assert(contains(w.text(), "done <<< \"$(branch=$(cat BRANCH))\"\n"));
static assert(contains(w.text(), "if ! out=$(gh workflow run \"$flow\" -R \"$repo\" \"$@\" 2>&1); then\n"));

// `hasUnresolved` refuses any `${` in a rite, so a dispatch that contains one
// never reaches a process: measured as a performance sitting on WEB for 27
// minutes with holds=0 and the driver looping.
static assert(!hasBraces(w.text()));
static assert(!hasBraces(s.text()));

// A target that does not split is a script ground must not run.
static assert(!dispatchScript("long-coin.yml", "").ok);

// A workflow_dispatch answers 204 with no body, so the run has to carry a name
// ground chose or newest-first is a guess.
enum k = dispatchScript("sbvh-nl/grove long-coin.yml", "", "coinflip-8ir:FLIP1");
static assert(k.ok);
static assert(contains(k.text(), "-f ground='coinflip-8ir:FLIP1'"));

// The token is <performance>:<rite>, so ground rebuilds it rather than reading
// it back out of the rite's stdout and into the line you read.
static assert(!contains(k.text(), "printf 'ground="));

// No token, no input — a workflow that does not declare it refuses the whole
// dispatch, and every pbt on disk predates this.
static assert(!contains(s.text(), "-f ground="));

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
