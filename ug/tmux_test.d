module tmux_test;

// CTFE tests — failure shows as a compile error.

import tmux : glyphColour, isJson, itemsInto, sinceInto, oneLineInto;
import tmux : GREEN, RED, DIM, PLAIN;

// tmux renders its own markup and prints ANSI literally, so nothing here may
// carry an escape.
static assert(glyphColour("+") == GREEN);
static assert(glyphColour("!") == RED);
static assert(glyphColour("?") is null);
static assert(glyphColour("") is null);

// The node spells the row itself once the format parameter ships. Until then
// it serves items, and both have to be read.
static assert(isJson(`{"items":[]}`));
static assert(isJson("  \n{\"items\":[]}"));
static assert(!isJson("#[fg=colour34]capy#[default]"));
static assert(!isJson(""));

char[512] drawn(const(char)[] body_)() {
    char[512] buf = '.';
    itemsInto(body_, buf[]);
    return buf;
}

size_t drawnLen(const(char)[] body_) {
    char[512] buf = '.';
    return itemsInto(body_, buf[]);
}

enum served = `{"items":[` ~
    `{"name":"capy","note":"0.244.0","glyph":"+"},` ~
    `{"name":"duif","glyph":"!"}]}`;

enum want =
    GREEN ~ "capy" ~ PLAIN ~ " " ~ DIM ~ "0.244.0" ~ PLAIN ~ "  " ~
    RED ~ "duif" ~ PLAIN;

static assert(drawnLen(served) == want.length);
static assert(drawn!served()[0 .. want.length] == want);

// An item with no note draws no trailing space and no empty span.
static assert(drawnLen(`{"items":[{"name":"x","glyph":"+"}]}`)
              == (GREEN ~ "x" ~ PLAIN).length);

// A glyph this build has no colour for draws nothing rather than being
// guessed at as well.
static assert(drawnLen(`{"items":[{"name":"x","glyph":"?"}]}`) == 0);

// Nothing to say is nothing drawn.
static assert(drawnLen(`{"items":[]}`) == 0);

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

char[128] week(long pct, long resetsAt, long now)() {
    char[128] buf = '.';
    weekInto(pct, resetsAt, now, buf[]);
    return buf;
}

enum DAY = 86_400;
enum weekHalf = DIM ~ "claude week 51% 3d 2h left" ~ PLAIN;
static assert(week!(51, 1000 + 3 * DAY + 2 * 3600 + 59, 1000)()[0 .. weekHalf.length] == weekHalf);

enum weekHot = RED ~ "claude week 98% 5h left" ~ PLAIN;
static assert(week!(98, 1000 + 5 * 3600, 1000)()[0 .. weekHot.length] == weekHot);

enum weekLast = RED ~ "claude week 85% 40m left" ~ PLAIN;
static assert(week!(85, 1000 + 40 * 60, 1000)()[0 .. weekLast.length] == weekLast);

static assert(weekInto(62, 1000 + DAY, 1000, new char[128]) > 0, "62 is inside 60 to 62");
static assert(weekInto(63, 1000 + DAY, 1000, new char[128]) == 0, "63 is between bands");
static assert(weekInto(24, 1000 + DAY, 1000, new char[128]) == 0);

// A window that has already reset says nothing about the one running now.
static assert(weekInto(98, 900, 1000, new char[128]) == 0);
static assert(weekInto(-1, 1000 + DAY, 1000, new char[128]) == 0, "no reading is not zero percent");
