module mycelia_test;

// CTFE tests — failure shows as a compile error.

// "so, why would the part that asks the node, not be able to be its own tiny binary"
// mycelia asks the node and keeps the row it learned; ground_tmux draws what
// is kept and asks nothing.
import mycelia : keptPathInto, keptOf, keptInto, silentInto, SILENT;
import tmux : RED, PLAIN;

// Where the row is kept, under home.
char[128] keptPath(const(char)[] home)() {
    char[128] buf = '.';
    keptPathInto(home, buf[]);
    return buf;
}

enum kept = "/h/.local/state/ug/mycelia";
static assert(keptPathInto("/h", new char[128]) == kept.length);
static assert(keptPath!"/h"()[0 .. kept.length] == kept);
static assert(keptPath!"/h/"()[0 .. kept.length] == kept, "a home ending in / is the same home");
static assert(keptPathInto("", new char[128]) == 0, "no home is nowhere to keep it");

// What is kept: when mycelia last asked, and the row it drew from the answer.
static assert(keptInto(1000, "#[fg=colour34]QNTX#[default]", new char[64]) == "1000\n#[fg=colour34]QNTX#[default]".length);
static assert(keptOf("1000\n#[fg=colour34]QNTX#[default]").at == 1000);
static assert(keptOf("1000\n#[fg=colour34]QNTX#[default]").line == "#[fg=colour34]QNTX#[default]");
static assert(keptOf("1000\n").line == "", "a pass that drew nothing kept an empty row");
static assert(keptOf("").at == 0, "nothing kept is no pass");
static assert(keptOf("x\nrow").at == 0, "a stamp that is not a number is no pass");

// A row kept longer ago than mycelia's passes go is a mycelia that stopped
// asking. That is said, and the row it last kept is not drawn as if current.
char[96] silent(long since)() {
    char[96] buf = '.';
    silentInto(since, buf[]);
    return buf;
}

static assert(SILENT > 0);
enum sixMinutes = RED ~ "mycelia silent 6 minutes" ~ PLAIN;
static assert(silent!(6 * 60)()[0 .. sixMinutes.length] == sixMinutes);
enum oneHour = RED ~ "mycelia silent 1 hour" ~ PLAIN;
static assert(silent!(3600)()[0 .. oneHour.length] == oneHour);
enum never = RED ~ "mycelia silent" ~ PLAIN;
static assert(silentInto(-1, new char[96]) == never.length, "never kept anything");
static assert(silent!(-1)()[0 .. never.length] == never);
