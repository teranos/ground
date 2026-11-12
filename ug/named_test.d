module named_test;

// "AGENTS CAN TALK TO EACH OTHER BY THEIR NAME"

import core.stdc.stdio : printf, fopen, fputs, fclose;
import core.stdc.stdlib : exit;
import core.sys.posix.sys.stat : mkdir;
import named;

extern (C) char* mkdtemp(char* tmpl);

void check(bool ok, const(char)* what) {
    if (ok) return;
    printf("named_test: %s\n", what);
    exit(1);
}

void keep(const(char)[] home, const(char)[] session, const(char)[] text) {
    char[600] p = 0;
    size_t o;
    void put(const(char)[] s) { foreach (c; s) p[o++] = c; }
    put(home); put("/.qntx"); p[o] = 0; mkdir(&p[0], 448);
    put("/sessions"); p[o] = 0; mkdir(&p[0], 448);
    put("/"); put(session); p[o] = 0; mkdir(&p[0], 448);
    put("/name"); p[o] = 0;
    auto f = fopen(&p[0], "w");
    check(f !is null, "a session's name file was not written");
    char[300] t = 0;
    foreach (i, c; text) t[i] = c;
    fputs(&t[0], f);
    fclose(f);
}

extern (C) int main() {
    char[64] tmpl = "/tmp/ug-named-XXXXXX\0";
    auto made = mkdtemp(&tmpl[0]);
    check(made !is null, "no home of the test's own");
    size_t n = 0;
    while (made[n] != 0) n++;
    auto home = made[0 .. n];

    char[128] dest = 0;
    check(sessionKeeping(home, "Alder", dest[]) == 0, "a name was found where no session is");

    keep(home, "ses-alder", "Alder\nhttps://api.q.sbvh.nl\nuser\n");
    keep(home, "ses-birch", "Alder Birch\nhttps://api.q.sbvh.nl\nitself\n");

    auto got = sessionKeeping(home, "Alder", dest[]);
    check(dest[0 .. got] == "ses-alder", "Alder is not the session that keeps Alder");
    got = sessionKeeping(home, "Alder Birch", dest[]);
    check(dest[0 .. got] == "ses-birch", "a name of two words is not its session's");
    check(sessionKeeping(home, "Slate", dest[]) == 0, "a name no session here keeps was given one");
    check(sessionKeeping(home, "", dest[]) == 0, "no name was given a session");
    return 0;
}
