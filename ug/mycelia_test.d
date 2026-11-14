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

// "for knowing what is incoming"
// "and also what is outbound,"
// What is collected for each agent (QNTX server/collected.go), kept as the
// node answered it, beside the row.
import mycelia : collectedPathInto, COLLECTED, refusedInto;
import qntx : State;

static assert(COLLECTED == "/api/collected");

char[128] collectedPath(const(char)[] home)() {
    char[128] buf = '.';
    collectedPathInto(home, buf[]);
    return buf;
}

enum collected = "/h/.local/state/ug/collected";
static assert(collectedPathInto("/h", new char[128]) == collected.length);
static assert(collectedPath!"/h"()[0 .. collected.length] == collected);
static assert(collectedPathInto("", new char[128]) == 0);

// What the node did not answer is kept in its place, in words: the reader
// says it, and never draws an old answer as the current one.
char[64] refused(State s, int status)() {
    char[64] buf = '.';
    refusedInto(s, status, buf[]);
    return buf;
}

enum badGateway = "QNTX 502";
static assert(refusedInto(State.serverError, 502, new char[64]) == badGateway.length);
static assert(refused!(State.serverError, 502)()[0 .. badGateway.length] == badGateway);
enum timedOut = "QNTX timeout";
static assert(refused!(State.timeout, 0)()[0 .. timedOut.length] == timedOut);
enum noKey = "QNTX key";
static assert(refused!(State.noKey, 0)()[0 .. noKey.length] == noKey);

// "mycelia connect needs to also be a thing"
// The key mycelia asks with is the one a person says yes to at the node, so
// mycelia is what connects it. With no verb it asks, pass after pass.
import mycelia : verbOf, Verb;

static assert(verbOf(null) == Verb.ask);
static assert(verbOf("connect") == Verb.connect);
static assert(verbOf("conect") == Verb.unknown, "a verb mycelia does not know is said, not run as the loop");

// "kept. kept bro, i want to put my finger on, and then not have to thing about it anymore"
// A press is the person's, made in the session the person holds (QNTX
// ADR-060). mycelia is a door onto the node, as the app is: the passkey is
// done at home, the node sends the browser back to mycelia://door with a
// ticket, and mycelia collects the session with it.
import mycelia : DOOR, homeUrlInto, ticketOf, resultUrlInto, sessionSaidPathInto;

static assert(DOOR == "mycelia://door");

char[256] homeUrl(const(char)[] host)() {
    char[256] buf = '.';
    homeUrlInto(host, buf[]);
    return buf;
}

enum home = "https://api.q.sbvh.nl/auth/door/home?door=mycelia%3A%2F%2Fdoor";
static assert(homeUrlInto("https://api.q.sbvh.nl", new char[256]) == home.length);
static assert(homeUrl!"https://api.q.sbvh.nl"()[0 .. home.length] == home);
static assert(homeUrlInto("", new char[256]) == 0, "no node is nowhere to go home to");

// The node sends the browser back as door?home=<ticket>; a ticket is
// base64url, so it is taken as it stands.
static assert(ticketOf("mycelia://door?home=AbC-_9") == "AbC-_9");
static assert(ticketOf("mycelia://door?home=AbC-_9&other=x") == "AbC-_9");
static assert(ticketOf("mycelia://door?x=1&home=AbC") == "AbC");
static assert(ticketOf("mycelia://door").length == 0, "no ticket is nothing to collect");
static assert(ticketOf("qntx://door?home=AbC").length == 0, "another door's ticket is not mycelia's");

char[256] resultUrl(const(char)[] host, const(char)[] ticket)() {
    char[256] buf = '.';
    resultUrlInto(host, ticket, buf[]);
    return buf;
}

enum result = "https://api.q.sbvh.nl/auth/door/home/result?home=AbC-_9&door=mycelia%3A%2F%2Fdoor";
static assert(resultUrlInto("https://api.q.sbvh.nl", "AbC-_9", new char[256]) == result.length);
static assert(resultUrl!("https://api.q.sbvh.nl", "AbC-_9")()[0 .. result.length] == result);

// What mycelia says of the session it collected, or why it did not: written
// down beside the row, never the session itself, for mycelia connect to say.
char[128] sessionSaidPath(const(char)[] home)() {
    char[128] buf = '.';
    sessionSaidPathInto(home, buf[]);
    return buf;
}

enum said = "/h/.local/state/ug/session";
static assert(sessionSaidPathInto("/h", new char[128]) == said.length);
static assert(sessionSaidPath!"/h"()[0 .. said.length] == said);
static assert(sessionSaidPathInto("", new char[128]) == 0);

// What a press asks mycelia to make in the person's session: a path and a
// body, on two lines and the rest. Only what a person does with what is
// collected is made there; anything else asked of the socket is refused.
import mycelia : pressOf, pressAllowed, SOCKET;

static assert(SOCKET == ".local/state/ug/mycelia.sock");
static assert(pressOf("/api/collected/cancel\n{\"to\":\"a\",\"id\":\"b\"}").path == "/api/collected/cancel");
static assert(pressOf("/api/collected/cancel\n{\"to\":\"a\",\"id\":\"b\"}").body_ == "{\"to\":\"a\",\"id\":\"b\"}");
static assert(pressOf("/api/collected/release\n{\"says\":\"one\\ntwo\"}").body_ == "{\"says\":\"one\\ntwo\"}");
static assert(pressOf("no line").path.length == 0, "a request with no line is no press");

static assert(pressAllowed("/api/collected/release"));
static assert(pressAllowed("/api/collected/hold"));
static assert(pressAllowed("/api/collected/later"));
static assert(pressAllowed("/api/collected/cancel"));
static assert(pressAllowed("/api/collected/edit"));
static assert(!pressAllowed("/api/collected"), "listing is mycelia's own, signed by ground's key");
static assert(!pressAllowed("/auth/admit"), "the person's session admits nobody through the socket");
static assert(!pressAllowed("/auth/tokens"), "the person's session mints nothing through the socket");
static assert(!pressAllowed("/api/collected/release/../../auth/admit"));
static assert(!pressAllowed("/api/collected/releasex"));
