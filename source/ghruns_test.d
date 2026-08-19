module ghruns_test;

// A push starts several workflows at once and the API returns them newest
// first. Reading one run means reading whichever finished last, so a red lint
// sitting two rows under a green deploy is never seen.

import ghruns : nextRun, rollupRuns, RunVerdict;

enum runs = `{"total_count":5,"workflow_runs":[`
    ~ `{"id":11,"name":"deploy","conclusion":"success","status":"completed","event":"push"},`
    ~ `{"id":12,"name":"lint","conclusion":"failure","status":"completed","event":"push"},`
    ~ `{"id":13,"name":"Rust","conclusion":null,"status":"in_progress","event":"push"},`
    ~ `{"id":14,"name":"lint","conclusion":"success","status":"completed","event":"push"},`
    ~ `{"id":15,"name":"Rust","conclusion":"success","status":"completed","event":"push"}`
    ~ `]}`;

unittest {
    auto a = nextRun(runs, 0);
    assert(a.ok);
    assert(a.name == "deploy");
    assert(a.conclusion == "success");

    auto b = nextRun(runs, a.next);
    assert(b.ok);
    assert(b.name == "lint");
    assert(b.conclusion == "failure");

    auto c = nextRun(runs, b.next);
    assert(c.ok);
    assert(c.name == "Rust");
    assert(c.status == "in_progress");
    assert(c.conclusion.length == 0, "a run still going has concluded nothing");
}

unittest {
    // A run carries nested objects that have a name of their own. The walk
    // must not come back with the committer or the repository.
    enum nested = `{"workflow_runs":[{"id":1,"name":"Rust","conclusion":"failure",`
        ~ `"status":"completed","head_commit":{"author":{"name":"someone"}},`
        ~ `"repository":{"name":"widget","full_name":"acme/widget"}}]}`;
    auto r = nextRun(nested, 0);
    assert(r.ok);
    assert(r.name == "Rust");
    assert(r.conclusion == "failure");
    assert(!nextRun(nested, r.next).ok, "one run, and the nesting did not split it");
}

unittest {
    // The walk reaches every run, not just the first page of one object.
    size_t n = 0;
    size_t from = 0;
    while (true) {
        auto r = nextRun(runs, from);
        if (!r.ok) break;
        from = r.next;
        n++;
    }
    assert(n == 5);
}

unittest {
    // Newest first, so the first sighting of a name is the run that counts.
    // lint's older green must not bury its newer red.
    auto v = rollupRuns(runs);
    assert(v.workflows == 3, "deploy, lint and Rust");
    assert(v.failedCount == 1);
    assert(v.failures[0].name == "lint");
    assert(v.failures[0].conclusion == "failure");

    // The log fetch asks for a run by id. Without the failing run's own id it
    // would list runs again and take the newest, which is the first bug over.
    assert(v.failures[0].id == 12);
    assert(v.failures[0].event == "push");
}

unittest {
    // Every workflow that failed, not the first one found. One green among
    // four reds is still a red branch, and naming one hides the others.
    enum manyRed = `{"workflow_runs":[`
        ~ `{"id":21,"name":"deploy","conclusion":"success","status":"completed","event":"push"},`
        ~ `{"id":22,"name":"lint","conclusion":"failure","status":"completed","event":"push"},`
        ~ `{"id":23,"name":"typecheck","conclusion":"failure","status":"completed","event":"push"},`
        ~ `{"id":24,"name":"Nix","conclusion":"timed_out","status":"completed","event":"push"}]}`;
    auto v = rollupRuns(manyRed);
    assert(v.workflows == 4);
    assert(v.failedCount == 3);
    assert(v.failures[0].name == "lint");
    assert(v.failures[1].name == "typecheck");
    assert(v.failures[2].name == "Nix");
    assert(v.failures[2].conclusion == "timed_out");
    assert(v.failures[1].id == 23);
}

unittest {
    auto a = nextRun(runs, 0);
    assert(a.id == 11);
    assert(a.event == "push");
}

unittest {
    enum allGreen = `{"workflow_runs":[`
        ~ `{"name":"a","conclusion":"success","status":"completed"},`
        ~ `{"name":"b","conclusion":"success","status":"completed"}]}`;
    auto v = rollupRuns(allGreen);
    assert(v.failedCount == 0);
    assert(!v.running);
    assert(v.workflows == 2);
}

unittest {
    // Nothing concluded yet is not the same as nothing wrong.
    enum pending = `{"workflow_runs":[{"name":"a","conclusion":null,"status":"queued"}]}`;
    auto v = rollupRuns(pending);
    assert(v.failedCount == 0);
    assert(v.running);
}

unittest {
    // An empty list is a repo with no run on this branch, and it is not green.
    enum none = `{"total_count":0,"workflow_runs":[]}`;
    auto v = rollupRuns(none);
    assert(v.workflows == 0);
    assert(v.failedCount == 0);
    assert(!v.running);

    assert(!nextRun(none, 0).ok);
    assert(!nextRun("", 0).ok);
}

unittest {
    // cancelled and timed_out are failures to a reader waiting on a verdict.
    enum killed = `{"workflow_runs":[`
        ~ `{"name":"a","conclusion":"cancelled","status":"completed"},`
        ~ `{"name":"b","conclusion":"success","status":"completed"}]}`;
    auto v = rollupRuns(killed);
    assert(v.failedCount == 1);
    assert(v.failures[0].conclusion == "cancelled");
}
