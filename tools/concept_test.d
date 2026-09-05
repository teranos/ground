module concept_test;

// CTFE tests for where a case belongs. A chapter is a concept, and the grammar
// has more words than it has concepts.

import concept : conceptOf, isConcept, chapters, rank, opener, chapterOf, moduleName;

// "most chapters arent supposed to be their own standalone chapters"
static assert(chapters.length == 6);

// "i still think it should come first, if its not its own chapter it would
// otherwise still be something you introduce before talking about controls"
static assert(chapters[0] == "scope");
static assert(chapters[1] == "control");
static assert(chapters[2] == "project");
static assert(chapters[3] == "permission");
static assert(chapters[4] == "ritual");
static assert(chapters[5] == "attestation");

static assert(isConcept("control"));
static assert(isConcept("project"));
static assert(isConcept("permission"));
static assert(isConcept("ritual"));
static assert(isConcept("attestation"));

// A scope takes arguments — a path, an event, a command — and every one of
// them governs what sits inside it. That is not punctuation.
static assert(isConcept("scope"));

// "another way to say it is just Attestation"
// The block carries a url and nothing else, so it is where an attestation is
// sent rather than a thing of its own.
static assert(!isConcept("qntx"));

// "rites is a rituals concept"
static assert(!isConcept("rites"));

// A D module with no pbt form is not a chapter.
static assert(!isConcept("adaptive"));
static assert(!isConcept("binary"));
static assert(!isConcept("zbuf"));

// The most specific block wins. A scope wrapping a control is an example of
// the control: the scope is where it sits, not what it shows.
static assert(conceptOf("scope {\n  control {\n    cmd: \"git\"\n  }\n}") == "control");

// A scope on its own shows where a rule stands, which is the whole of what a
// scope is. Answering nothing dropped every example that taught one.
static assert(conceptOf("scope {\n  path: \"/ground\"\n}") == "scope");

// A scope inside a scope is what its example is about. The nesting is the
// lesson, and the control at the bottom of it is only what inherits.
static assert(conceptOf(
    "scope {\n  path: \"/a\"\n  scope {\n    control {\n      cmd: \"git\"\n    }\n  }\n}") == "scope");

// A ritual lives inside a project, and the example is about the ritual.
static assert(conceptOf("project {\n  ritual green {\n  }\n}") == "ritual");

// A project with no ritual in it is a project example.
static assert(conceptOf("project {\n  path: \"/x\"\n}") == "project");

// A rite is what a ritual is made of, so its example is the ritual's.
static assert(conceptOf("rites green {\n  built { eval: `make` }\n}") == "ritual");

// Permission carries its mode on the block name, so the word is a prefix
// rather than a whole line.
static assert(conceptOf("permission.rw.pa {\n  allow: [\"/x\"]\n}") == "permission");
static assert(conceptOf("permission {\n  deny: [\"rm\"]\n}") == "permission");

// An attestation and the node it is posted to are one subject.
static assert(conceptOf("attestation {\n  subject: \"x\"\n}") == "attestation");
static assert(conceptOf("qntx {\n  node {\n    url: \"http://x\"\n  }\n}") == "attestation");

// Text that is not pbt belongs to no chapter.
static assert(conceptOf("") == "");
static assert(conceptOf("hello world") == "");
static assert(conceptOf("include \"other.pbt\"") == "");

// "that sounds like its devoid of meneaning or chronology"
// A chapter opened on whichever filename sorted first. The grammar of a
// control is what it is, so it is met before any one thing done with it.
static assert(rank("control", "proto") < rank("control", "binary"));
static assert(rank("control", "proto") < rank("control", "playbill"));
static assert(rank("control", "project") < rank("control", "binary"));

// An exemption is the last thing a reader needs, not the first.
static assert(rank("control", "binary") > rank("control", "control_ritual"));

// A module the order does not name stands behind every module it does, so a
// new test file lands at the back rather than in front of the definition.
static assert(rank("control", "zbuf") > rank("control", "binary"));
static assert(rank("control", "zbuf") == size_t.max);

// A chapter with no order of its own leaves its modules level, which is the
// order press already found them in.
static assert(rank("attestation", "qntx") == rank("attestation", "zbuf"));

// "the first one should be about control as a concept"
// A chapter opens on the module that says what the concept is, and that is the
// first one its own order names.
static assert(opener("control") == "hooks");
static assert(rank("control", "hooks") == 0);

// Where a rule stands is what matcher decides, so it is what says what a
// scope is. A module opens one chapter: only its first heading is taken.
static assert(opener("scope") == "matcher");
static assert(rank("scope", "proto") > rank("scope", "matcher"));

// A chapter with no order opens on nothing, and its first case stands alone
// the way every chapter did before one was written.
static assert(opener("attestation") == "");

// "so its deliberate which terms deserve a glossary entry"
// A glossary term belongs to the chapter that owns its module, and a chapter
// owns a module by naming it. Naming is the whole of the decision.
static assert(chapterOf("matcher") == "scope");
static assert(chapterOf("hooks") == "control");
static assert(chapterOf("permission") == "permission");
static assert(chapterOf("rite") == "ritual");
static assert(chapterOf("mic") == "ritual");

// A module nobody names owns no term, so a glossary line in it is a line the
// book refuses rather than one it files somewhere.
static assert(chapterOf("zbuf") == "");

// The reading order of a chapter is not ownership. proto is read under both
// scope and control and owns terms for neither.
static assert(chapterOf("proto") == "");

// A module under source/ritual/ is named with its directory, so the ritual's
// own modules are reachable and nothing beside them can be mistaken for them.
static assert(moduleName("source/ritual/position.d") == "ritual/position");
static assert(moduleName("source/rite.d") == "rite");
static assert(moduleName("source/proto_test.d") == "proto");
static assert(chapterOf("ritual/position") == "ritual");
