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
