module row_test;

import row : effortGlyph;

// "Why dont i always see it, what effort we are on? like in the statusline?"
// "low    = 🔫"
// "medium = ✨"
// "high   = 🔥"
// "xhigh  = ❤️‍🔥"
// "max    = 💥"
// The row's glyph is the effort the turn runs at, as Claude Code hands it to
// the status line.
static assert(effortGlyph("low") == "🔫");
static assert(effortGlyph("medium") == "✨");
static assert(effortGlyph("high") == "🔥");
static assert(effortGlyph("xhigh") == "❤️‍🔥");
static assert(effortGlyph("max") == "💥");
// A model that takes no effort is handed none, and no glyph says one.
static assert(effortGlyph("") == "");
static assert(effortGlyph("auto") == "");
