module tmux_test;

// CTFE tests — failure shows as a compile error.

import tmux : isJson, sinceInto, oneLineInto;
import tmux : GREEN, RED, DIM, PLAIN;

// The JSON row is read for news and deploys; the tmux line is printed.
static assert(isJson(`{"items":[]}`));
static assert(isJson("  \n{\"items\":[]}"));
static assert(!isJson("#[fg=colour34]capy#[default]"));
static assert(!isJson(""));

char[256] since(long s)() {
    char[256] buf = '.';
    sinceInto(s, buf[]);
    return buf;
}

// The largest unit that is still true, and it agrees with itself about the
// plural.
enum oneMinute = RED ~ "QNTX unreachable 1 minute" ~ PLAIN;
static assert(since!60()[0 .. oneMinute.length] == oneMinute);

enum sixMinutes = RED ~ "QNTX unreachable 6 minutes" ~ PLAIN;
static assert(since!(6 * 60)()[0 .. sixMinutes.length] == sixMinutes);

enum twoHours = RED ~ "QNTX unreachable 2 hours" ~ PLAIN;
static assert(since!(2 * 3600)()[0 .. twoHours.length] == twoHours);

enum threeDays = RED ~ "QNTX unreachable 3 days" ~ PLAIN;
static assert(since!(3 * 86400)()[0 .. threeDays.length] == threeDays);

char[64] oneLine(const(char)[] s)() {
    char[64] buf = '.';
    oneLineInto(s, buf[]);
    return buf;
}

// tmux takes the first line of a #() and drops the rest, so the row stops at
// the first break rather than losing everything after it silently.
static assert(oneLineInto("abc\ndef", new char[64]) == 3);
static assert(oneLine!"abc\ndef"()[0 .. 3] == "abc");
static assert(oneLineInto("abc", new char[64]) == 3);
static assert(oneLineInto("", new char[64]) == 0);

// An org's Actions minutes are on the bar only inside the bands asked for:
// 50 to 52, 60 to 62, 70 to 75, and 80 and over. Anywhere else the number is
// not worth the room, so it is not drawn.
import tmux : bandColour, minutesInto, YELLOW, ORANGE;

static assert(bandColour(999, 2000) is null, "49% is not yet a band");
static assert(bandColour(1000, 2000) == DIM, "50%");
static assert(bandColour(1059, 2000) == DIM, "52.9% is still between 50 and 52");
static assert(bandColour(1060, 2000) is null, "53% has left it");
static assert(bandColour(1199, 2000) is null);
static assert(bandColour(1200, 2000) == YELLOW, "60%");
static assert(bandColour(1259, 2000) == YELLOW);
static assert(bandColour(1260, 2000) is null);
static assert(bandColour(1400, 2000) == ORANGE, "70%");
static assert(bandColour(1519, 2000) == ORANGE, "75.9%");
static assert(bandColour(1520, 2000) is null, "76 to 79 is between bands");
static assert(bandColour(1600, 2000) == RED, "80%");
static assert(bandColour(2007, 2000) == RED, "past the quota is still 80 and over");

// No reading and no quota are not zero percent.
static assert(bandColour(-1, 2000) is null, "asked and not yet answered");
static assert(bandColour(500, 0) is null, "an org that states no quota has nothing to be a percentage of");

char[128] minutes(const(char)[] org, long used, long quota)() {
    char[128] buf = '.';
    minutesInto(org, used, quota, buf[]);
    return buf;
}

// The org, the percentage, and the two numbers it came from.
enum half = DIM ~ "abcd-nl actions 51% 1020/2000" ~ PLAIN;
static assert(minutes!("abcd-nl", 1020, 2000)()[0 .. half.length] == half);

enum over = RED ~ "abcd-nl actions 100% 2007/2000" ~ PLAIN;
static assert(minutes!("abcd-nl", 2007, 2000)()[0 .. over.length] == over);

// Outside a band nothing is written at all.
static assert(minutesInto("abcd-nl", 900, 2000, new char[128]) == 0);

// "i want something similar for the weekly claude usage, also in the tmux ug"
// The same four bands, read off the weekly window ug itself records, with how
// long until it resets: that is the half of the number only this side knows.
import tmux : weekInto;

char[128] week(string label, long pct, long resetsAt, long now)() {
    char[128] buf = '.';
    weekInto(label, pct, resetsAt, now, buf[]);
    return buf;
}

enum DAY = 86_400;

// "just remove the y / right now i see it twice / instead y needs to be shown
// onece / before ccMAX". Both weeks reset within a minute of each other, so
// the row was spending the room twice to say one thing. The week carries the
// label and the percentage and nothing else.
enum weekHalf = DIM ~ "ccMAX 51%" ~ PLAIN;
static assert(week!("ccMAX", 51, 1000 + 3 * DAY + 2 * 3600 + 59, 1000)()[0 .. weekHalf.length] == weekHalf);

enum weekHot = RED ~ "ccMAX 98%" ~ PLAIN;
static assert(week!("ccMAX", 98, 1000 + 5 * 3600, 1000)()[0 .. weekHot.length] == weekHot);

// "y ccMAX xx%" — the time stands once, in front, in its own hand.
import tmux : leftInto;

char[32] until(long resetsAt, long now)() {
    char[32] buf = '.';
    leftInto(resetsAt, now, buf[]);
    return buf;
}

static assert(until!(1000 + 3 * DAY + 2 * 3600 + 59, 1000)()[0 .. 2] == "3d");
static assert(leftInto(1000 + 3 * DAY + 2 * 3600 + 59, 1000, new char[32]) == 2);
static assert(until!(1000 + 5 * 3600, 1000)()[0 .. 2] == "5h");
static assert(until!(1000 + 40 * 60, 1000)()[0 .. 3] == "40m");

// The hour that used to carry its minutes carries them no longer.
static assert(until!(1000 + 2 * 3600 + 20 * 60, 1000)()[0 .. 2] == "2h");

// A window already reset has no time in front of it.
static assert(leftInto(900, 1000, new char[32]) == 0);
static assert(leftInto(1000, 1000, new char[32]) == 0);

static assert(weekInto("ccMAX", 62, 1000 + DAY, 1000, new char[128]) > 0, "62 is inside 60 to 62");
static assert(weekInto("ccMAX", 63, 1000 + DAY, 1000, new char[128]) == 0, "63 is between bands");
static assert(weekInto("ccMAX", 24, 1000 + DAY, 1000, new char[128]) == 0);

// A window that has already reset says nothing about the one running now.
static assert(weekInto("ccMAX", 98, 900, 1000, new char[128]) == 0);
static assert(weekInto("ccMAX", -1, 1000 + DAY, 1000, new char[128]) == 0, "no reading is not zero percent");

// "i wish we also knew about fable usage better"
// The Fable window is the same bands under its own name.
enum fableWarm = ORANGE ~ "FABLE 71%" ~ PLAIN;
static assert(week!("FABLE", 71, 1000 + 4 * DAY + 21 * 3600 + 5, 1000)()[0 .. fableWarm.length] == fableWarm);

// "MAX is only MAX if the subscription plan is max like ground usage displays"
// The plan is `subscriptionType` from `claude auth status`, which ground asks
// for and writes down as the `plan` check; `ground usage` prints it as `Plan
// max`. The label spells whatever that says, so a week on another plan cannot
// be read as a Max week.
import tmux : weekLabelInto;

char[16] label(const(char)[] plan)() {
    char[16] buf = '.';
    weekLabelInto(plan, buf[]);
    return buf;
}

static assert(weekLabelInto("max", new char[16]) == 5);
static assert(label!"max"()[0 .. 5] == "ccMAX");
static assert(label!"pro"()[0 .. 5] == "ccPRO");
static assert(label!"team"()[0 .. 6] == "ccTEAM");

// A plan nobody has asked for yet is not a Max plan. The reading is still
// worth the room, so the window keeps its name and claims nothing else.
static assert(weekLabelInto("", new char[16]) == 2);
static assert(label!""()[0 .. 2] == "cc");

// A dest too small truncates rather than writing past it.
static assert(weekLabelInto("max", new char[3]) == 3);

// A deploy is drawn on the plugin's own name: behind its letters, green from
// the left a step for each check that passed, then purple as far as the node's
// own build is, the letters not reached yellow.
import tmux : filledNameInto, deployInto, deploysOverInto, Fill, CHECKED, BUILT, TO_GO, FAILED;

char[512] named(const(char)[] name, Fill checks, Fill node)() {
    char[512] buf = '.';
    filledNameInto(name, checks, node, buf[]);
    return buf;
}

enum notBuilt = Fill(0, 3, false, true);

// One check of eight passed: green behind the c, the rest yellow.
enum oneOfEight = CHECKED ~ "c" ~ TO_GO ~ "leanAPI" ~ PLAIN;
static assert(named!("cleanAPI", Fill(1, 8, false, true), notBuilt)()[0 .. oneOfEight.length] == oneOfEight);

// Two of eight: the l is green as well.
enum twoOfEight = CHECKED ~ "cl" ~ TO_GO ~ "eanAPI" ~ PLAIN;
static assert(named!("cleanAPI", Fill(2, 8, false, true), notBuilt)()[0 .. twoOfEight.length] == twoOfEight);

// No check heard yet: none of it green.
enum noneYet = TO_GO ~ "cleanAPI" ~ PLAIN;
static assert(named!("cleanAPI", Fill(0, 0, false, true), notBuilt)()[0 .. noneYet.length] == noneYet);

// Every check passed: the whole name green.
enum allPassed = CHECKED ~ "cleanAPI" ~ PLAIN;
static assert(named!("cleanAPI", Fill(3, 3, false, true), notBuilt)()[0 .. allPassed.length] == allPassed);

// The node building, one stage of three: purple over the first third.
enum buildingName = BUILT ~ "cl" ~ CHECKED ~ "eanAPI" ~ PLAIN;
static assert(named!("cleanAPI", Fill(3, 3, false, true), Fill(1, 3, false, true))()[0 .. buildingName.length] == buildingName);

// A deploy no push began has no checks, and is green behind all of it.
enum unpushed = BUILT ~ "clean" ~ CHECKED ~ "API" ~ PLAIN;
static assert(named!("cleanAPI", Fill.init, Fill(2, 3, false, true))()[0 .. unpushed.length] == unpushed);

// A failure is red and still.
enum failed = FAILED ~ "cleanAPI" ~ PLAIN;
static assert(named!("cleanAPI", Fill(1, 3, true, true), notBuilt)()[0 .. failed.length] == failed);

// The node's deploy data, as it said datapunt's 0.3.11 deploy on 2026-10-13,
// drawn on the name alone. Nothing is written beside it.
import tmux : epochOf, FINISHED;

enum t0 = epochOf("2026-10-13T07:30:00Z");
static assert(epochOf("2026-10-13T07:30:03.232259168Z") == t0 + 3);
static assert(epochOf("1970-01-01T00:00:00Z") == 0);

char[1024] deployed(const(char)[] obj, long now, long newest)() {
    char[1024] buf = '.';
    deployInto(obj, now, newest, buf[]);
    return buf;
}

// Waiting on its one check: all of it yellow.
enum waiting = `{"plugin":"datapunt","stage":"checks","repo":"teranos/datapunt","pushed":true,"rev":"943796a",` ~
    `"checks":{"test":"waiting"},"began":{"checks":"2026-10-13T07:30:03.232259168Z"}}`;
enum waitingDrawn = TO_GO ~ "datapunt" ~ PLAIN;
static assert(deployed!(waiting, t0 + 10, 0)()[0 .. waitingDrawn.length] == waitingDrawn);

// Two of four checks passed: green behind half the name.
enum halfway = `{"plugin":"datapunt","stage":"checks","repo":"teranos/datapunt","pushed":true,"rev":"943796a",` ~
    `"checks":{"a":"done","b":"done","c":"running","d":"waiting"},"began":{"checks":"2026-10-13T07:30:03Z"}}`;
enum halfwayDrawn = CHECKED ~ "data" ~ TO_GO ~ "punt" ~ PLAIN;
static assert(deployed!(halfway, t0 + 10, 0)()[0 .. halfwayDrawn.length] == halfwayDrawn);

// Checks passed, the node building: purple over a third, green after.
enum building = `{"plugin":"datapunt","stage":"building","repo":"teranos/datapunt","pushed":true,"rev":"943796a",` ~
    `"checks":{"test":"done"},"began":{"building":"2026-10-13T07:30:49Z","checks":"2026-10-13T07:30:03Z"}}`;
enum buildingDrawn = BUILT ~ "da" ~ CHECKED ~ "tapunt" ~ PLAIN;
static assert(deployed!(building, t0 + 60, 0)()[0 .. buildingDrawn.length] == buildingDrawn);

// The build said its version: every other turn it takes the name's place,
// the name padded to its width.
enum versioned = `{"plugin":"datapunt","stage":"restarting","repo":"teranos/datapunt","pushed":true,"rev":"943796a",` ~
    `"checks":{"test":"done"},"version":"0.3.11-8ed95ff65b864797","began":{"restarting":"2026-10-13T07:31:09Z"}}`;
enum nameTurn = BUILT ~ "datapunt       " ~ CHECKED ~ "        " ~ PLAIN;
// t0 is a multiple of 4 seconds, so t0 + 72 is the name's turn and t0 + 74 the version's.
static assert(t0 % 4 == 0);
static assert(deployed!(versioned, t0 + 72, 0)()[0 .. nameTurn.length] == nameTurn);
enum versionTurn = BUILT ~ "0.3.11-8ed95ff6" ~ CHECKED ~ "5b864797" ~ PLAIN;
static assert(deployed!(versioned, t0 + 74, 0)()[0 .. versionTurn.length] == versionTurn);

// Live: the slight blink, for a moment, then nothing.
enum live = `{"plugin":"datapunt","stage":"live","repo":"teranos/datapunt","pushed":true,"rev":"943796a",` ~
    `"checks":{"test":"done"},"began":{"live":"2026-10-13T07:31:10Z"}}`;
enum liveDrawn = FINISHED ~ "datapunt" ~ PLAIN;
static assert(deployed!(live, t0 + 72, 0)()[0 .. liveDrawn.length] == liveDrawn);
static assert(deployInto(live, t0 + 80, 0, new char[1024]) == 0);

// Failed: red, until time or other news.
enum failing = `{"plugin":"datapunt","stage":"failed","repo":"teranos/datapunt","pushed":true,"rev":"943796a",` ~
    `"checks":{"test":"failed"},"began":{"failed":"2026-10-13T07:31:00Z"},"failed_at":"checks"}`;
enum failingDrawn = FAILED ~ "datapunt" ~ PLAIN;
static assert(deployed!(failing, t0 + 90, 0)()[0 .. failingDrawn.length] == failingDrawn);
static assert(deployInto(failing, t0 + 60 + 120, 0, new char[1024]) == 0, "time did not clear it");
static assert(deployInto(failing, t0 + 90, t0 + 70, new char[1024]) == 0, "other news did not clear it");

// An unchanged build is over, and draws nothing.
static assert(deployInto(`{"plugin":"datapunt","stage":"unchanged","began":{}}`, t0, 0, new char[256]) == 0);

// The deploy takes the place of its plugin's item on the line the node spelled.
enum spelled = `#[range=user|QNTX]#[fg=colour34]QNTX#[default]#[norange]  ` ~
    `#[range=user|datapunt]#[fg=colour34]datapunt#[default] #[fg=colour244]0.3.10-8ed95ff65b864797#[default]#[norange]`;
enum servedRow = `{"items":[{"name":"QNTX","symbol":"+"}],"deploys":[` ~ building ~ `]}`;
enum overDrawn = `#[range=user|QNTX]#[fg=colour34]QNTX#[default]#[norange]  ` ~
    `#[range=user|datapunt]` ~ buildingDrawn ~ `#[norange]`;

char[4096] overed(const(char)[] line, const(char)[] body_, long now)() {
    char[4096] buf = '.';
    deploysOverInto(line, body_, now, buf[]);
    return buf;
}

static assert(deploysOverInto(spelled, servedRow, t0 + 60, new char[4096]) == overDrawn.length);
static assert(overed!(spelled, servedRow, t0 + 60)()[0 .. overDrawn.length] == overDrawn);

// A row with no deploy in flight is the line as the node spelled it.
static assert(overed!(spelled, `{"items":[],"deploys":[]}`, t0)()[0 .. spelled.length] == spelled);
static assert(overed!(spelled, `{"items":[]}`, t0)()[0 .. spelled.length] == spelled);

// "click with my mouse cursor on the specific plugin in the statusline, and see
// a plugin version of the statusline, and then click again, and get back"
import tmux : isPluginName, rowPathInto;

static assert(isPluginName("cleanAPI"));
static assert(isPluginName("openrouter-qntx"));
static assert(!isPluginName(""));
static assert(!isPluginName("POST .me.draft"), "a route on a plugin's row is not a plugin");
static assert(!isPluginName("a&b"));

char[160] rowPath(const(char)[] focus, const(char)[] format)() {
    char[160] buf = '.';
    rowPathInto(focus, format, buf[]);
    return buf;
}

enum nodeRow = "/am/statusline?format=tmux";
static assert(rowPathInto(null, "tmux", new char[160]) == nodeRow.length);
static assert(rowPath!(null, "tmux")()[0 .. nodeRow.length] == nodeRow);

enum cleanRow = "/am/statusline?format=tmux&plugin=cleanAPI";
static assert(rowPath!("cleanAPI", "tmux")()[0 .. cleanRow.length] == cleanRow);

// A focus that is not a plugin's name asks for the node's row, never for it.
static assert(rowPathInto("a&b", "tmux", new char[160]) == nodeRow.length);

// --- a state the bar can draw ---

// The words live in qntx.d and were drawn by nothing: every one of them was
// written, tested and unreachable. This is the renderer that asks for them.
import tmux : stateInto;
import qntx : State;

enum wantKeyless = YELLOW ~ "QNTX token" ~ PLAIN;
static assert(() {
    char[64] b = 0;
    auto n = stateInto(State.noToken, b[]);
    return b[0 .. n] == wantKeyless;
}());

// Not ours to fix reads red, the way a status does.
enum wantDns = RED ~ "QNTX dns" ~ PLAIN;
static assert(() {
    char[64] b = 0;
    auto n = stateInto(State.dnsFailure, b[]);
    return b[0 .. n] == wantDns;
}());

// Fine draws nothing, because the absence of the row is what fine looks like.
static assert(() {
    char[64] b = 0;
    return stateInto(State.ok, b[]) == 0;
}());
