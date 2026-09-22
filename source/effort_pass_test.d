module effort_pass_test;

// "setting it manuall should override any setting ground puts, or ground
// should fire a msg when it lowers the effort"
//
// The message already fires — sky puts what the pass said into its batch. The
// override did not exist: a pin held the key until the window fell, and gave
// back what was there when it pinned, over whatever a person had put in
// between. A pin now owns the key only while the key still holds what the pin
// wrote. Anything else there was put there by a person, and the pin lets go.

import effort : Pin, openPin, pin, release, overridden, decide, Move;

unittest {
    import db : sqlite3, sqlite3_open, sqlite3_close, applySchema, SQLITE_OK;

    sqlite3* db;
    assert(sqlite3_open(":memory:\0".ptr, &db) == SQLITE_OK);
    assert(applySchema(db));

    // A pin is one model's. Another model's pin is not it.
    assert(!openPin(db, "claude-opus-5").open);
    assert(pin(db, "claude-opus-5", "high", "medium", 860, 1000));
    assert(openPin(db, "claude-opus-5").open);
    assert(!openPin(db, "claude-fable-5-1").open, "one model's pin is not another's");

    auto p = openPin(db, "claude-opus-5");
    assert(p.before() == "high", "what was there when it pinned");
    assert(p.wrote() == "medium", "what it put there");

    // Two models hold their own pins at once.
    assert(pin(db, "claude-fable-5-1", "", "low", 900, 1000));
    assert(openPin(db, "claude-fable-5-1").wrote() == "low");
    assert(openPin(db, "claude-opus-5").wrote() == "medium", "and neither disturbs the other");

    assert(release(db, p.id, 700, 2000, "window"));
    assert(!openPin(db, "claude-opus-5").open);
    assert(openPin(db, "claude-fable-5-1").open, "releasing one leaves the other");

    // A pin let go because a person changed the key says so, and is not
    // released twice.
    auto f = openPin(db, "claude-fable-5-1");
    assert(overridden(db, f.id, 900, 3000));
    assert(!openPin(db, "claude-fable-5-1").open);
    assert(!overridden(db, f.id, 900, 3001));

    sqlite3_close(db);
}

// A pin from before there was a model wrote the top-level key, which stands
// for every model at once. No ladder looks at that pin any more, so nothing
// would ever release it and the key it wrote would sit there for good. It is
// handed back once, on the first pass that meets it.
unittest {
    import db : sqlite3, sqlite3_open, sqlite3_close, applySchema, SQLITE_OK;
    import effort : legacyPin;

    sqlite3* db;
    assert(sqlite3_open(":memory:\0".ptr, &db) == SQLITE_OK);
    assert(applySchema(db));

    assert(!legacyPin(db).open, "a store with no such pin has nothing to hand back");

    assert(pin(db, "", "high", "low", 890, 1000));
    auto old = legacyPin(db);
    assert(old.open && old.before() == "high");

    // A pin that names its model is this ground's, not the old one's.
    assert(pin(db, "claude-opus-5", "", "medium", 810, 1000));
    assert(legacyPin(db).id == old.id, "and is not mistaken for it");

    assert(release(db, old.id, 890, 2000, "legacy"));
    assert(!legacyPin(db).open);

    sqlite3_close(db);
}

// --- what one look decides, before anything is written ---

// No pin and a reading that asks for nothing: nothing happens.
static assert(decide(false, "", "", "", "high") == Move.nothing);

// No pin and a reading that asks: take the key.
static assert(decide(false, "medium", "", "", "high") == Move.take);

// Holding the key, and the reading still asks for what is written: nothing.
static assert(decide(true, "medium", "medium", "medium", "high") == Move.nothing);

// Holding the key, and the reading now asks for less room: move it.
static assert(decide(true, "low", "medium", "medium", "high") == Move.move);

// Holding the key, and the window has fallen: give it back.
static assert(decide(true, "", "medium", "medium", "high") == Move.give);

// "setting it manuall should override any setting ground puts"
// Holding the key, and the key says something ground did not write: a person
// did, and the pin lets go without touching it — whether the window still
// asks for something or not.
static assert(decide(true, "low", "medium", "high", "high") == Move.letGo);
static assert(decide(true, "", "medium", "high", "high") == Move.letGo);
static assert(decide(true, "medium", "medium", "xhigh", "high") == Move.letGo);

// A key emptied by hand is still a person's doing.
static assert(decide(true, "low", "medium", "", "high") == Move.letGo);
