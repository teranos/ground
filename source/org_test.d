module org_test;

// An org is what several projects have in common and none of them owns: the
// GitHub organisation their CI minutes are counted against, and where they
// report. A project names its org, the way a ritual names its rites.

import proto : parsePbt, validateOrgs;
import count : countPbt;
import ritual : flatten, resolveSentry, dsnAt;
import org : githubName;

enum orgs = `
org utility_company {
  github: "https://github.com/abcd-nl"

  # GitHub says how many minutes were used and never how many were included.
  actions_minutes: 2000

  sentry {
    dsn: "https://org@o1.ingest.example/9"
  }
}

org PLAIN {
  github: "https://github.com/teranos"
}

sentry {
  dsn: "https://top@o1.ingest.example/1"
}

rites walk {
  ONE {
    eval: "true"
  }
}
`;

// Four projects: one that takes its org's word, one that says nearer, one whose
// org says nothing, and one that names no org at all.
enum projects = `
project {
  path: "/src/grove"
  org: utility_company

  ritual grove {
    walk
  }
}

project {
  path: "/src/own"
  org: utility_company

  sentry {
    dsn: "https://proj@o1.ingest.example/2"
  }

  ritual own {
    walk
  }
}

project {
  path: "/src/plain"
  org: PLAIN

  ritual plain {
    walk
  }
}

project {
  path: "/src/loose"

  ritual loose {
    walk
  }
}
`;
// The whole is what the parts say, composed rather than written twice.
enum src = orgs ~ projects;
enum parsed = parsePbt(src);

static assert(parsed.orgCount == 2);
static assert(parsed.orgs[0].name == "utility_company");
static assert(parsed.orgs[0].github == "https://github.com/abcd-nl");
static assert(parsed.orgs[0].actionsMinutes == 2000);
static assert(parsed.orgs[0].sentry.dsn == "https://org@o1.ingest.example/9");
static assert(parsed.orgs[1].name == "PLAIN");
static assert(parsed.orgs[1].actionsMinutes == 0, "an org that names no quota has none to measure against");
static assert(parsed.projects[0].org == "utility_company");
static assert(parsed.projects[3].org == "");
static assert(validateOrgs(parsed).text() == "");

// Pass 1 walks the same text first. A block it does not know stops the build
// before the parser runs, which is how the first real sentry block was met.
static assert(countPbt(src).totalProjects == 4);

// The name GitHub knows the org by is the end of its url.
static assert(githubName("https://github.com/abcd-nl") == "abcd-nl");
static assert(githubName("https://github.com/abcd-nl/") == "abcd-nl");
static assert(githubName("abcd-nl") == "abcd-nl");
static assert(githubName("") == "");

// The org is the outer layer of where a performance reports: ritual, then
// project, then the project's org. The top level answers only for a project
// that names no org, or whose org says nothing.
static assert(resolveSentry(flatten(parsed, 0).sentry) == "https://org@o1.ingest.example/9");
static assert(resolveSentry(flatten(parsed, 1).sentry) == "https://proj@o1.ingest.example/2");
static assert(resolveSentry(flatten(parsed, 2).sentry) == "https://top@o1.ingest.example/1");
static assert(resolveSentry(flatten(parsed, 3).sentry) == "https://top@o1.ingest.example/1");

// The same for something that is no ritual's, asked of a place.
static assert(dsnAt(parsed, "/home/u/src/grove") == "https://org@o1.ingest.example/9");
static assert(dsnAt(parsed, "/home/u/src/own") == "https://proj@o1.ingest.example/2");
static assert(dsnAt(parsed, "/home/u/src/plain") == "https://top@o1.ingest.example/1");
static assert(dsnAt(parsed, "/elsewhere") == "https://top@o1.ingest.example/1");

// A project naming an org nobody declared is refused by name.
enum strayed = parsePbt(`
project {
  path: "/p"
  org: NOBODY
}
`);
static assert(validateOrgs(strayed).text() == "project /p: no org named NOBODY");

// Two orgs under one name are two candidates for every project that names it.
enum twice = parsePbt(`
org A {
  github: "https://github.com/a"
}
org A {
  github: "https://github.com/b"
}
`);
static assert(validateOrgs(twice).text() == "org A is declared twice");

// An org is named, and an unknown field inside one is refused rather than
// skipped: a misspelled quota would otherwise measure against nothing.
static assert(!__traits(compiles, { enum bad = parsePbt("org {\n  github: \"x\"\n}\n"); }));
static assert(!__traits(compiles, { enum bad = parsePbt("org A {\n  action_minutes: 2000\n}\n"); }));
