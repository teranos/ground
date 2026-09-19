module effort_test;

// "if Fable usage is 85%+ its effort needs to be set to lowest automatically"
// The Fable week is the reading ug asks the usage endpoint for. From 85.0
// the sky writes effortLevel "low" into the user settings, keeps what was
// there, and writes it back when the window is under again — a new week.
import effort : PIN_AT, PINNED, pinWanted, effortIn, settingsWith;

static assert(PIN_AT == 850, "tenths of a percent, as the usage table keeps it");
static assert(PINNED == "low", "the lowest of low, medium, high, xhigh, max");
static assert(pinWanted(850));
static assert(pinWanted(1000));
static assert(!pinWanted(849));
static assert(!pinWanted(-1), "no reading is no reason");

// The setting as it stands: the string, or empty for null and for absent.
static assert(effortIn(`{"model": "opus[1m]", "effortLevel": "high", "theme": "dark"}`) == "high");
static assert(effortIn(`{"effortLevel":null}`) == "");
static assert(effortIn(`{"model": "opus[1m]"}`) == "");

// The settings with the one key changed and nothing else touched: replaced
// where it is, put first where it is not, and null is how it is given back
// when there was none.
private string rewritten(string text, string value)() {
    char[256] buf = 0;
    auto n = settingsWith(text, value, buf[]);
    return buf[0 .. n].idup;
}
static assert(rewritten!(`{"model": "opus[1m]", "effortLevel": "high", "theme": "dark"}`, `"low"`)()
    == `{"model": "opus[1m]", "effortLevel": "low", "theme": "dark"}`);
static assert(rewritten!("{\n  \"model\": \"opus[1m]\",\n  \"theme\": \"dark\"\n}", `"low"`)()
    == "{\n  \"effortLevel\": \"low\",\n  \"model\": \"opus[1m]\",\n  \"theme\": \"dark\"\n}");
static assert(rewritten!(`{"effortLevel": "low", "theme": "dark"}`, "null")()
    == `{"effortLevel": null, "theme": "dark"}`);
static assert(rewritten!(`{"effortLevel":null}`, `"high"`)() == `{"effortLevel":"high"}`);
// Not a settings object: copied as it is, so nothing is written over it.
static assert(rewritten!("", `"low"`)() == "");
static assert(rewritten!("not json", `"low"`)() == "not json");
// A file the buffer cannot hold is not half-written.
static assert(() { char[8] small = 0; return settingsWith(`{"effortLevel": "high"}`, `"low"`, small[]); }() == 0);
