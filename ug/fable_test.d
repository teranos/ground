module fable_test;

// CTFE tests — failure shows as a compile error.

// "i wish we also knew about fable usage better"
// "i had no idea i was getting to 70 so fast"

import fable : fableIn, epochOf, FABLE, MODEL;

// The answer /api/oauth/usage gave on 2026-09-18 21:13, cut to what matters:
// every seven_day_* key null, and the model window inside limits alone.
enum answer = `{"five_hour":{"utilization":5.0,"resets_at":"2026-09-18T22:30:00.517702+00:00"},`
    ~ `"seven_day":{"utilization":52.0,"resets_at":"2026-09-23T19:00:00.517728+00:00"},`
    ~ `"seven_day_omelette":null,"nimbus_quill":{"utilization":0.0,"resets_at":null},`
    ~ `"limits":[`
    ~ `{"kind":"session","group":"session","percent":5,"severity":"normal","resets_at":"2026-09-18T22:30:00.517702+00:00","scope":null,"is_active":false},`
    ~ `{"kind":"weekly_all","group":"weekly","percent":52,"severity":"normal","resets_at":"2026-09-23T19:00:00.517728+00:00","scope":null,"is_active":false},`
    ~ `{"kind":"weekly_scoped","group":"weekly","percent":76,"severity":"warning","resets_at":"2026-09-23T18:59:59.517964+00:00","scope":{"model":{"id":null,"display_name":"Fable"},"surface":null},"is_active":true}`
    ~ `],"seven_day_breakdown":{"rows":[{"key":"claude_code","display_name":"Claude Code","percent":95}]}}`;

static assert(FABLE == "fable_week");
static assert(MODEL == "Fable");

static assert(fableIn(answer).present);
static assert(fableIn(answer).percent == "76");
static assert(fableIn(answer).resetsAt == 1790189999);

// An account with no model window has no such entry, and that is absent, not
// zero percent.
enum unscoped = `{"limits":[{"kind":"weekly_all","group":"weekly","percent":52,"scope":null}]}`;
static assert(!fableIn(unscoped).present);

// Fable named outside limits is not the window: the breakdown rows carry a
// display_name and a percent of their own.
enum elsewhere = `{"limits":[],"seven_day_breakdown":{"rows":[{"key":"x","display_name":"Fable","percent":95}]}}`;
static assert(!fableIn(elsewhere).present);
static assert(!fableIn("").present);

// resets_at arrives as text with an offset; the store keeps epochs like the
// windows Claude Code hands over.
static assert(epochOf("2026-09-23T19:00:00.517728+00:00") == 1790190000);
static assert(epochOf("2026-09-23T18:59:59.517964+00:00") == 1790189999);
static assert(epochOf("2026-09-23T20:59:59+02:00") == 1790189999);
static assert(epochOf("2026-09-23T18:59:59Z") == 1790189999);
static assert(epochOf("null") == 0);
static assert(epochOf("") == 0);
