module substitute_test;

// "the file that was being read, using any command, get's Read into claude as
// it tries to use one of the command line utilities set in the
// substitute_for_read parameter"

import substitute : readTargets;

// static immutable, not enum: an enum array literal is materialised at every
// use, and materialising one at runtime wants TypeInfo, which -betterC has not.
static immutable string[3] utils = ["sed", "awk", "perl"];

private bool one(const(char)[] cmd, const(char)[] want) {
    auto t = readTargets(cmd, utils[]);
    return t.count == 1 && t.paths[0] == want;
}

// Every command below is a real one, taken from `ground shovel PreToolUse`
// over the past two weeks.

// The dominant sed shape: a window into a file, path last.
static assert(one("sed -n '780,830p' source/immediate.d", "source/immediate.d"));
static assert(one("sed -n '90,140p' plugin/grpc/watchers.go", "plugin/grpc/watchers.go"));

// The script is not always quoted, so "unquoted last token" cannot be the rule.
static assert(one("sed -n 185,320p /home/golem/SBVH/teranos/ground/source/db.d",
                  "/home/golem/SBVH/teranos/ground/source/db.d"));

// awk reading a file directly — four of nineteen did.
static assert(one(`awk '/extractLeadingCd/{print NR": "$0}' source/matcher.d`,
                  "source/matcher.d"));

// perl is almost always an in-place write, which is the case the ban exists
// for: a file changed without ever being read.
static assert(one(`perl -pi -e 's/^\treal//' server/auth/laye.go`, "server/auth/laye.go"));

// And it takes several files at once.
enum many = readTargets(
    `perl -pi -e 's/reportHttpSuccess/reportReachable/g' ts/sync-badge.test.ts ts/test-setup.ts ts/client/http.test.ts`,
    utils[]);
static assert(many.count == 3);
static assert(many.paths[0] == "ts/sync-badge.test.ts");
static assert(many.paths[2] == "ts/client/http.test.ts");

// Most awk and much sed consumes a pipe. There is no file to hand over, and
// the command must be left alone.
static assert(readTargets(`ps aux | sort -nrk 3 | awk '{printf "%s%% %s\n", $3, $11}'`, utils[]).count == 0);
static assert(readTargets("aws connect transfer-contact help 2>&1 | sed -n '1,60p'", utils[]).count == 0);
static assert(readTargets(`git diff --stat main...HEAD | sed 's/|.*//'`, utils[]).count == 0);

// The letters appear inside other words. `elapsed` and `unused` are why
// `ground shovel PreToolUse sed` was itself refused.
static assert(readTargets(`sleep 400; echo "W400 elapsed"`, utils[]).count == 0);
static assert(readTargets(`cargo build 2>&1 | grep -E "^warning: unused"`, utils[]).count == 0);
static assert(readTargets("sed_placeholder=1; grep -n foo bar.go", utils[]).count == 0);

// A utility not named in the control is not its business.
static assert(readTargets("grep -F needle haystack.txt", utils[]).count == 0);

// crowbar runs it on another machine. The path is not ours to read.
static assert(readTargets(`crowbar "sed -n '14,25p' /var/lib/qntx/am.toml"`, utils[]).count == 0);

// Nothing at all.
static assert(readTargets("", utils[]).count == 0);
static assert(readTargets("sed", utils[]).count == 0);
static assert(readTargets("sed --help", utils[]).count == 0);
