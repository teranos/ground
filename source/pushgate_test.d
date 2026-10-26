module pushgate_test;

// A push names its repository with -C; the gate reads that repository, not the
// directory the session stands in. The address is built from parts, so the
// source of this file carries none.

import libgit2_test : sh, scratch;
import matcher : checkAllCommands, MatchSet;

enum PAST_PRIVATE = "172.32." ~ "0.1";

bool refused(MatchSet set) {
    foreach (m; set.matches[0 .. set.count])
        if (m.control.name == "pushed-names-nobody") return true;
    return false;
}

unittest {
    auto repo = scratch("pushgate");
    auto r = repo.text();
    sh("git -C ", r, " init -q && printf '", PAST_PRIVATE, "\\n' > ", r, "/a.d && git -C ", r,
       " add a.d && git -C ", r, " -c user.name=t -c user.email=tim@example.com commit -q -m a");
    auto elsewhere = scratch("pushgate-cwd");

    auto push = scratch("cmd");
    push.n = 0;
    push.put("git -C ");
    push.put(r);
    push.put(" push");
    assert(refused(checkAllCommands(push.text(), elsewhere.text())), push.text());

    push.put(" origin --delete gone");
    assert(!refused(checkAllCommands(push.text(), elsewhere.text())), push.text());
}
