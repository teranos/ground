module onoff_test;

// BOOK_GLOSSARY **Rituals off**: What a project is until a session standing in it says rituals on: no new performance of its rituals starts, and one already running carries on.

// A project's rituals are off until a session standing in it says rituals on.

import proto : parsePbt;
import ritual : saidOf, Said, projectAt, ritualsOn, setRituals, offBecause, switched;
import db : sqlite3, sqlite3_open, sqlite3_close, applySchema, SQLITE_OK;

private sqlite3* memDb() {
    sqlite3* db;
    assert(sqlite3_open(":memory:\0".ptr, &db) == SQLITE_OK);
    assert(applySchema(db));
    return db;
}

unittest {
    // "all rituals are disabled by default, project sessions and paths opt into them"
    auto db = memDb();
    assert(!ritualsOn(db, "/teranos/QNTX"), "a project nobody switched is off");
    assert(offBecause(db, "/teranos/QNTX") ==
           "rituals are off for /teranos/QNTX; a session there says rituals on to let them fire");
    sqlite3_close(db);
}

unittest {
    // "if a ritual get's enabled or disabled, a controls fires as to give direct feedback as to what happens in a simple manner."
    auto db = memDb();
    char[512] buf;

    auto n = switched(db, parsed, Said.On, "/Users/x/teranos/QNTX/server", "", "", "s1", 1000, buf[]);
    assert(buf[0 .. n] == "rituals on for /teranos/QNTX: its rituals fire, for every session there, until one says rituals off");
    assert(ritualsOn(db, "/teranos/QNTX"));

    n = switched(db, parsed, Said.Off, "/Users/x/teranos/QNTX", "", "", "s1", 1001, buf[]);
    assert(buf[0 .. n] == "rituals off for /teranos/QNTX: no new performance of its rituals starts, for every session there, until one says rituals on; one already running carries on");
    assert(!ritualsOn(db, "/teranos/QNTX"));

    // Where no project stands, nothing is switched, and it says so.
    n = switched(db, parsed, Said.On, "/Users/x/elsewhere", "", "", "s1", 1002, buf[]);
    assert(buf[0 .. n] == "rituals on: no project { } block stands at /Users/x/elsewhere, so nothing was switched");
    sqlite3_close(db);
}

unittest {
    // "persitence is forever, the playbill is supposed to inform about this"
    auto db = memDb();
    assert(setRituals(db, "/teranos/QNTX", true, "session-a", 1000));
    assert(ritualsOn(db, "/teranos/QNTX"), "the store holds it, not the session that said it");
    assert(offBecause(db, "/teranos/QNTX") is null);
    sqlite3_close(db);
}

// "also for subdirs yes"
// A place under a project's path stands in that project.
enum nested = `
rites walk {
  ONE {
    eval: "true"
  }
}

project {
  path: "/teranos/QNTX"

  ritual deploy {
    walk
  }
}

project {
  path: "/teranos/QNTX/web"

  ritual site {
    walk
  }
}
`;
enum parsed = parsePbt(nested);

static assert(projectAt(parsed, "/Users/x/teranos/QNTX", "", "") == "/teranos/QNTX");
static assert(projectAt(parsed, "/Users/x/teranos/QNTX/server", "", "") == "/teranos/QNTX");

// "rituals off and rituals on take no arguments"
// "it should be easy for me to switch, simply by saying the words"
// A sentence with one of them inside it is a sentence, not the phrase.
static assert(saidOf("rituals on") == Said.On);
static assert(saidOf("rituals off") == Said.Off);
static assert(saidOf("  rituals off\n") == Said.Off);
static assert(saidOf("rituals off please") == Said.Nothing);
static assert(saidOf("are rituals on?") == Said.Nothing);
static assert(saidOf("") == Said.Nothing);

unittest {
    // "if session A is saying rituals off, no new rituals can fire there until either Session A or Session B say rituals on again"
    auto db = memDb();
    assert(setRituals(db, "/teranos/QNTX", true, "session-a", 1000));
    assert(setRituals(db, "/teranos/QNTX", false, "session-b", 1001));
    assert(!ritualsOn(db, "/teranos/QNTX"), "the last one said is the one that holds");
    assert(setRituals(db, "/teranos/QNTX", true, "session-a", 1002));
    assert(ritualsOn(db, "/teranos/QNTX"));
    sqlite3_close(db);
}

// "rituals on or off is always tied to the project { } block"
// The deepest project wins, and a project inside another has a switch of its own.
static assert(projectAt(parsed, "/Users/x/teranos/QNTX/web/src", "", "") == "/teranos/QNTX/web");
static assert(projectAt(parsed, "/Users/x/teranos/QNTX-App", "", "") == "");
static assert(projectAt(parsed, "/Users/x/elsewhere", "", "") == "");

// A tree cut from the repo, wherever it sits on disk, is the repo's project.
static assert(projectAt(parsed, "/tmp/qntx-deploy-1000", "/Users/x/teranos/QNTX", "") == "/teranos/QNTX");

// A project that names its repo is every checkout of it.
enum byOrigin = `
rites walk {
  ONE {
    eval: "true"
  }
}

project {
  origin: "teranos/QNTX"
  path: "/teranos/QNTX"

  ritual deploy {
    walk
  }
}
`;
static assert(projectAt(parsePbt(byOrigin), "/tmp/qntx-chapter-1", "", "teranos/QNTX") == "/teranos/QNTX");

// A project block holding no ritual has nothing to switch, however deep it is.
enum wound = `
rites walk {
  ONE {
    eval: "true"
  }
}

project {
  path: "/teranos/ground"

  ritual jev {
    walk
  }
}

project {
  path: "/Users/x/teranos/ground"
  files: ["README.md"]
}
`;
static assert(projectAt(parsePbt(wound), "/Users/x/teranos/ground", "", "") == "/teranos/ground");
