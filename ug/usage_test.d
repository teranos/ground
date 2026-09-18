module usage_test;

// CTFE tests — failure shows as a compile error. The cancelled-frame behaviour
// is live_test.d's, run by make test-ug-live.

// "i want to record the usage that is left in ground itself"
// "once every 4 hours"
// "and always a fresh one on starting a new session"

import usage : rateLimits, attestationInto, RECORD_EVERY, CLAIM_SQL, UPDATE_SQL;

enum both = `{"context_window":{"used_percentage":12.5},"rate_limits":{"five_hour":{"used_percentage":23.5,"resets_at":1738425600},"seven_day":{"used_percentage":41.2,"resets_at":1738857600}}}`;

// The number is kept as Claude Code wrote it: 23.5 is not 23.
static assert(rateLimits(both).w[0].name == "five_hour");
static assert(rateLimits(both).w[0].present);
static assert(rateLimits(both).w[0].percent == "23.5");
static assert(rateLimits(both).w[0].resetsAt == 1738425600);
static assert(rateLimits(both).w[1].name == "seven_day");
static assert(rateLimits(both).w[1].percent == "41.2");
static assert(rateLimits(both).w[1].resetsAt == 1738857600);

// context_window carries a used_percentage too. Read from the whole input, the
// first one found is whichever the payload happens to put first.
enum contextLast = `{"rate_limits":{"seven_day":{"used_percentage":41.2,"resets_at":1}},"context_window":{"used_percentage":12.5}}`;
static assert(!rateLimits(contextLast).w[0].present);
static assert(rateLimits(contextLast).w[1].percent == "41.2");

// A window Claude Code dropped is absent, not zero percent used.
enum capture = import("captures/grove/in.json");
static assert(!rateLimits(capture).w[0].present);
static assert(!rateLimits(capture).w[1].present);

// "i wish we also knew about fable usage better"
// The third window is never in the payload. ug asks for it, so its claim goes
// in with no reading and ask_exit -2 until the ask outside the frame answers.
import usage : NAMES, ASKED, PENDING;
static assert(NAMES[2] == "fable_week");
static assert(!rateLimits(both).w[2].present);
static assert(rateLimits(both).w[2].name == "fable_week");
static assert(PENDING == "-1");
static assert(ASKED == -2);
static assert(contains(CLAIM_SQL, "ask_exit"));
static assert(contains(CLAIM_SQL, "SELECT ?1, ?2, ?3, ?4, ?5, 0, -2, ?7"));

// The rule is the claim: a new session, or the interval since the last reading.
static assert(RECORD_EVERY == 14400);
static assert(contains(CLAIM_SQL, "INSERT INTO usage (window, used_percentage, resets_at, seen_at, session, qntx_status, qntx_exit, ask_exit)"));
static assert(contains(CLAIM_SQL, "NOT EXISTS (SELECT 1 FROM usage WHERE window = ?1 AND session = ?5)"));
static assert(contains(CLAIM_SQL, "NOT EXISTS (SELECT 1 FROM usage WHERE window = ?1 AND seen_at > ?4 - ?6)"));

// The weekly window is drawn on the tmux bar inside bands two points wide, and
// a reading every four hours steps over a band whole. So each whole percent of
// a week is written down the first time it is seen: a hundred rows a week at
// the most, and never the same one twice.
static assert(contains(CLAIM_SQL, "OR (?1 = 'seven_day' AND NOT EXISTS (SELECT 1 FROM usage WHERE window = ?1 AND resets_at = ?3 "
    ~ "AND CAST(used_percentage AS INTEGER) = CAST(?2 AS INTEGER)))"));

// -2 until the attempt outside the frame says how it went.
static assert(contains(CLAIM_SQL, "?5, 0, -2"));
static assert(contains(UPDATE_SQL, "SET qntx_status = ?1, qntx_exit = ?2 WHERE id = ?3"));

// "and these shoudl also be attempted to be attested into qntx"
char[512] bodyOf(const(char)[] input, size_t i, const(char)[] session)() {
    char[512] buf = 0;
    attestationInto(rateLimits(input).w[i], session, buf[]);
    return buf;
}
enum wantBody = `{"subjects":["five_hour"],"predicates":["rate_limit"],"contexts":["session:s-1"],"actors":["ug"],"attributes":{"used_percentage":23.5,"resets_at":1738425600}}`;
static assert(bodyOf!(both, 0, "s-1")()[0 .. wantBody.length] == wantBody);
static assert(bodyOf!(both, 0, "s-1")()[wantBody.length] == 0);

// "so if ug sees this, it can say, with 2h left, i will decide to attest every 10 min"
// Only the weekly window, and only in its last two hours. Everything else keeps
// the four-hour rhythm, and a window already reset is not near its reset.
import usage : intervalFor, NEAR_RESET, NEAR_EVERY, CLOSE_RESET, CLOSE_EVERY, SHORT_EVERY;

enum RESET = 1789592400;
static assert(NEAR_RESET == 7200);
static assert(NEAR_EVERY == 600);
static assert(intervalFor("seven_day", RESET, RESET - 7200) == 600);
static assert(intervalFor("seven_day", RESET, RESET - 60) == 600);
static assert(intervalFor("seven_day", RESET, RESET) == 14400);

// A five-hour window read every four hours is stale for most of its life. It is
// read every quarter of an hour, and every ten minutes in its last two.
static assert(SHORT_EVERY == 900);
static assert(intervalFor("five_hour", RESET, RESET - 60) == 600);
static assert(intervalFor("five_hour", RESET, RESET - 7200) == 600);
static assert(intervalFor("five_hour", RESET, RESET - 7201) == 900);
static assert(intervalFor("five_hour", RESET, RESET - 4 * 3600) == 900);
static assert(intervalFor("five_hour", RESET, RESET) == 900);

// "i had no idea i was getting to 70 so fast"
// The Fable window moved 76 points in the first day of its week, measured
// 2026-09-18. It is asked at the five-hour window's rhythm: every quarter of an
// hour, and every ten minutes in its last two.
static assert(intervalFor("fable_week", RESET, RESET - 4 * 3600) == 900);
static assert(intervalFor("fable_week", RESET, RESET - 7200) == 600);
static assert(intervalFor("fable_week", 0, RESET) == 900);

// "you could even say, we go from 4h cadence to 1h cadence if the time to hit limit is less than 48h"
// Between two days and two hours out, the weekly window is read every hour.
static assert(CLOSE_RESET == 172800);
static assert(CLOSE_EVERY == 3600);
static assert(intervalFor("seven_day", RESET, RESET - 7201) == 3600);
static assert(intervalFor("seven_day", RESET, RESET - 172800) == 3600);
static assert(intervalFor("seven_day", RESET, RESET - 172801) == 14400);

private bool contains(const(char)[] haystack, const(char)[] needle) {
    if (needle.length > haystack.length) return false;
    foreach (i; 0 .. haystack.length - needle.length + 1)
        if (haystack[i .. i + needle.length] == needle) return true;
    return false;
}
