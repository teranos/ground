module effort_ladder_test;

// "i think all sessions, all models are put on low right nwo becaes i hit the
// fable limit, but the fable limit should just apply to fable sessions"
// "the other sessions have nothing to do with fable limit being hit or not"
//
// Two windows, two ladders, and a key per model rather than the one key that
// stood for all of them. The account's week governs Opus and Sonnet; the Fable
// week governs Fable and nothing else.

import effort : MEDIUM_AT, ACCOUNT_LOW_AT, FABLE_LOW_AT, wantedFor,
                modelKey, modelEffortIn, settingsWithModel,
                FABLE_MODEL, ACCOUNT_MODELS;

// "for weekly 95+ should be put to low and 80+ should be set to medium"
static assert(MEDIUM_AT == 800, "tenths, as the usage table keeps a reading");
static assert(ACCOUNT_LOW_AT == 950);
// "fable's own 85+ would set it to low on 85+ limit hit"
static assert(FABLE_LOW_AT == 850);

// The account's ladder: nothing under 80, medium from 80, low from 95.
static assert(wantedFor(799, ACCOUNT_LOW_AT) == "");
static assert(wantedFor(800, ACCOUNT_LOW_AT) == "medium");
static assert(wantedFor(949, ACCOUNT_LOW_AT) == "medium");
static assert(wantedFor(950, ACCOUNT_LOW_AT) == "low");
static assert(wantedFor(1000, ACCOUNT_LOW_AT) == "low");

// Fable's ladder is the same step at 80 and a shorter climb to low.
static assert(wantedFor(799, FABLE_LOW_AT) == "");
static assert(wantedFor(800, FABLE_LOW_AT) == "medium");
static assert(wantedFor(849, FABLE_LOW_AT) == "medium");
static assert(wantedFor(850, FABLE_LOW_AT) == "low");

// "no reading is no reason" — and a window that has reset reads as none.
static assert(wantedFor(-1, ACCOUNT_LOW_AT) == "");
static assert(wantedFor(-1, FABLE_LOW_AT) == "");

// ground writes down claude-opus-5[1m]; modelSettings keys on claude-opus-5.
// The bracket is the context window, not another model.
static assert(modelKey("claude-opus-5[1m]") == "claude-opus-5");
static assert(modelKey("claude-opus-5") == "claude-opus-5");
static assert(modelKey("claude-fable-5-1") == "claude-fable-5-1");
static assert(modelKey("") == "");

// The models each window governs. Fable's week reaches one model; the
// account's week reaches the rest.
static assert(FABLE_MODEL == "claude-fable-5-1");
static assert(ACCOUNT_MODELS == ["claude-opus-5", "claude-sonnet-5"]);

// --- reading one model's setting ---

enum live = `{
  "effortLevel": "low",
  "theme": "dark",
  "modelSettings": {
    "claude-opus-5": {
      "effortLevel": "high"
    }
  }
}`;

static assert(modelEffortIn(live, "claude-opus-5") == "high");

// The top-level key is a different setting and must not answer for a model.
// This is the whole of the bug: one key stood for every model at once.
static assert(modelEffortIn(live, "claude-fable-5-1") == "");
static assert(modelEffortIn(`{"effortLevel": "low"}`, "claude-opus-5") == "");
static assert(modelEffortIn(`{"modelSettings": {}}`, "claude-opus-5") == "");
static assert(modelEffortIn(`{"modelSettings": {"claude-opus-5": {}}}`, "claude-opus-5") == "");

// A model named inside a string value is not a model setting.
static assert(modelEffortIn(`{"note": "modelSettings claude-opus-5 effortLevel high"}`,
                            "claude-opus-5") == "");

// --- writing one model's setting ---

private string wrote(string text, string model, string value)() {
    char[1024] buf = 0;
    auto n = settingsWithModel(text, model, value, buf[]);
    return buf[0 .. n].idup;
}

// Where the key is, it is replaced and nothing else moves.
static assert(wrote!(`{"modelSettings": {"claude-opus-5": {"effortLevel": "high"}}}`,
                     "claude-opus-5", `"medium"`)()
    == `{"modelSettings": {"claude-opus-5": {"effortLevel": "medium"}}}`);

// Where the model is and the key is not, the key goes in first.
static assert(wrote!(`{"modelSettings": {"claude-opus-5": {"theme": "dark"}}}`,
                     "claude-opus-5", `"low"`)()
    == `{"modelSettings": {"claude-opus-5": {"effortLevel": "low", "theme": "dark"}}}`);

// Where the model is not, the model goes in first.
static assert(wrote!(`{"modelSettings": {"claude-opus-5": {"effortLevel": "high"}}}`,
                     "claude-fable-5-1", `"low"`)()
    == `{"modelSettings": {"claude-fable-5-1": {"effortLevel": "low"}, "claude-opus-5": {"effortLevel": "high"}}}`);

// Where modelSettings is not, it goes in first.
static assert(wrote!(`{"theme": "dark"}`, "claude-opus-5", `"low"`)()
    == `{"modelSettings": {"claude-opus-5": {"effortLevel": "low"}}, "theme": "dark"}`);

// An empty object is still an object.
static assert(wrote!(`{}`, "claude-opus-5", `"low"`)()
    == `{"modelSettings": {"claude-opus-5": {"effortLevel": "low"}}}`);

// null is how a setting is given back when ground had nothing to restore.
static assert(wrote!(`{"modelSettings": {"claude-opus-5": {"effortLevel": "low"}}}`,
                     "claude-opus-5", "null")()
    == `{"modelSettings": {"claude-opus-5": {"effortLevel": null}}}`);

// The top-level key is never touched. It is the default for every model, and
// writing it is what dragged every session down.
static assert(wrote!(`{"effortLevel": "high", "modelSettings": {"claude-opus-5": {"effortLevel": "high"}}}`,
                     "claude-opus-5", `"low"`)()
    == `{"effortLevel": "high", "modelSettings": {"claude-opus-5": {"effortLevel": "low"}}}`);

// A settings file is read by a person. A member put into a pretty-printed
// object takes that object's own indentation and its own line, rather than
// leaving a compact seam across a file written one key to a line.
static assert(wrote!("{\n  \"modelSettings\": {\n    \"claude-opus-5\": {\n      \"effortLevel\": \"high\"\n    }\n  }\n}",
                     "claude-fable-5-1", `"low"`)()
    == "{\n  \"modelSettings\": {\n    \"claude-fable-5-1\": {\"effortLevel\": \"low\"},\n    \"claude-opus-5\": {\n      \"effortLevel\": \"high\"\n    }\n  }\n}");

// modelSettings itself, when the file has none, on its own line the same way.
static assert(wrote!("{\n  \"theme\": \"dark\"\n}", "claude-opus-5", `"low"`)()
    == "{\n  \"modelSettings\": {\"claude-opus-5\": {\"effortLevel\": \"low\"}},\n  \"theme\": \"dark\"\n}");

// A file written on one line stays on one line: the shape it had is the shape
// it keeps.
static assert(wrote!(`{"theme": "dark"}`, "claude-opus-5", `"low"`)()
    == `{"modelSettings": {"claude-opus-5": {"effortLevel": "low"}}, "theme": "dark"}`);

// Not a settings object: copied as it is, so nothing is written over it.
static assert(wrote!("", "claude-opus-5", `"low"`)() == "");
static assert(wrote!("not json", "claude-opus-5", `"low"`)() == "not json");

// A file the buffer cannot hold is not half-written.
static assert(() {
    char[8] small = 0;
    return settingsWithModel(`{"theme": "dark"}`, "claude-opus-5", `"low"`, small[]);
}() == 0);
