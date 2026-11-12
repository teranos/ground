module naming_test;

// "I WANT A SESSION TO BE ABLE TO GIVE ITSELF AN AVAILABLE NAME, AMONGST ALL PARTICIPANTS IN THE CLUSTER"

version (Posix):

import naming;
import fakenode : node, heardAll, http;
import matcher : indexOf;

enum ADMITTED = http!("200 OK", `{"did":"did:key:z6Mk","token_type":"Signed","expires_in":3600}`);
enum TAKEN = http!("403 Forbidden", `{"why":"not allowed","says":"\"Alder\" is taken: another agent holds it. Ask again with another name."}`);
enum NAMED = http!("200 OK", `{"name":"Alder","did":"did:key:z6Mk"}`);

// A home of the test's own, with ground's key kept in it.
private void testHome(ref char[256] home, ref char[256] key) {
    import core.stdc.stdio : snprintf;
    import core.sys.posix.stdlib : setenv;
    import core.sys.posix.unistd : getpid;
    import signed : keepKey;
    snprintf(home.ptr, home.length, "/tmp/ground-names-%d", getpid());
    snprintf(key.ptr, key.length, "/tmp/ground-names-%d/.qntx/key", getpid());
    setenv("HOME", home.ptr, 1);
    assert(keepKey(key.ptr).held, "ground's key was not kept");
}

// The session's key is admitted by ground's, signed; the name wanted is asked
// for, signed by the session's own key; and that is the name.
unittest {
    char[256] home, key;
    testHome(home, key);
    auto n = node(ADMITTED, NAMED);
    Named named;
    auto at = sessionKeyFile("ses-1");
    assert(at !is null);
    assert(nameSession(n.url, at, "Alder", named) == 1, named.why.slice());
    assert(named.name.slice() == "Alder", named.name.slice());
    assert(named.did.slice().length > "did:key:z".length, named.did.slice());
    auto heard = heardAll(n);
    assert(indexOf(heard, "POST /auth/admit HTTP/1.1") >= 0, heard);
    assert(indexOf(heard, "Content-Type: application/x-www-form-urlencoded") >= 0, heard);
    assert(indexOf(heard, "Authorization: Signed ") >= 0, heard);
    assert(indexOf(heard, "did=did%3Akey%3Az") >= 0, heard);
    assert(indexOf(heard, "&label=Alder") >= 0, heard);
    assert(indexOf(heard, "POST /i/name HTTP/1.1") >= 0, heard);
    assert(indexOf(heard, `{"name":"Alder"}`) >= 0, heard);
}

// A name another agent holds is taken: the session is told, and no other name
// is asked for in its place.
unittest {
    char[256] home, key;
    testHome(home, key);
    auto n = node(ADMITTED, TAKEN);
    Named named;
    assert(nameSession(n.url, sessionKeyFile("ses-taken"), "Alder", named) == -1);
    heardAll(n);
    assert(indexOf(named.why.slice(), "Alder is taken") >= 0, named.why.slice());
}

// "the name"
// "needs to stick"
// The name the node gave is kept beside the session's key, so the session
// asks for that one again and for no other.
unittest {
    char[256] home, key;
    testHome(home, key);
    auto n = node(ADMITTED, NAMED);
    Named named;
    auto at = sessionKeyFile("ses-kept");
    char[256] buf;
    assert(keptName(at, n.url, buf[]) is null, "a session never named keeps no name");
    assert(nameSession(n.url, at, "Alder", named) == 1, named.why.slice());
    heardAll(n);
    assert(named.why.len == 0, named.why.slice());
    assert(keptName(sessionKeyFile("ses-kept"), n.url, buf[]) == "Alder", keptName(sessionKeyFile("ses-kept"), n.url, buf[]));
    // A name is one node's to give: at another node this session keeps none.
    assert(keptName(sessionKeyFile("ses-kept"), "https://another.node", buf[]) is null, "a name one node gave was asked for at another");
}

// A node that will not admit the key says so, and no name is asked for.
unittest {
    char[256] home, key;
    testHome(home, key);
    auto n = node(http!("403 Forbidden", `{"error":"only a key the person said yes to admits a session's key"}`));
    Named named;
    assert(nameSession(n.url, sessionKeyFile("ses-2"), "Alder", named) == -1);
    heardAll(n);
    assert(indexOf(named.why.slice(), "/auth/admit answered 403") >= 0, named.why.slice());
    assert(indexOf(named.why.slice(), "only a key the person said yes to") >= 0, named.why.slice());
}

// The session's key path is its id's, under ~/.qntx/sessions.
unittest {
    char[256] home, key;
    testHome(home, key);
    auto at = sessionKeyFile("abc");
    size_t n = 0;
    while (at[n] != 0) n++;
    assert(indexOf(at[0 .. n], "/.qntx/sessions/abc/key") >= 0, at[0 .. n]);
    assert(sessionKeyFile("a/b") is null, "a slash in an id is no path of ours");
    // `..` would be ~/.qntx/key, the key the person said yes to.
    assert(sessionKeyFile("..") is null, "two dots as an id reach ground's own key");
    assert(sessionKeyFile(".") is null);
    assert(sessionKeyFile("s%") is null);
}

// An answer cut short, with no quote closing the name, names nobody.
unittest {
    char[256] home, key;
    testHome(home, key);
    auto n = node(ADMITTED, http!("200 OK", `{"name":"Ald`));
    Named named;
    assert(nameSession(n.url, sessionKeyFile("ses-cut"), "Alder", named) == -1);
    heardAll(n);
    assert(indexOf(named.why.slice(), "no whole name") >= 0, named.why.slice());
    char[256] buf;
    assert(keptName(sessionKeyFile("ses-cut"), n.url, buf[]) is null, "half a name was kept");
}
