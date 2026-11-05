module resume_test;

// "ITS THE SAME -BG SESSION THAT IS THE SAME ENTITY"
// A performance resumes its ritual's last session only while that session's transcript stands:
// resumed without one, regoto-wait-test-1793848550's agent was answered under its old id and
// ended one second in, and the walk went on with nobody in it.
import ritual.store : transcriptStands;

unittest {
    import core.sys.posix.stdlib : mkdtemp;
    import core.stdc.stdio : fopen, fclose, snprintf;
    import core.sys.posix.unistd : unlink, rmdir;
    import errors : mkdir;
    char[64] base = "/tmp/ground-projects-XXXXXX\0";
    assert(mkdtemp(base.ptr) !is null);
    size_t n = 0;
    while (base[n] != 0) n++;
    char[256] dir = 0, file = 0;
    snprintf(dir.ptr, dir.length, "%s/-Users-u-repo", base.ptr);
    snprintf(file.ptr, file.length, "%s/-Users-u-repo/05cf89a6-7fcb-41c9-b8cb-c38f12ab8f8f.jsonl", base.ptr);
    assert(mkdir(dir.ptr, 493) == 0);
    auto f = fopen(file.ptr, "w");
    import core.stdc.stdio : fputs;
    fputs(`{"type":"user","message":{"role":"user","content":"go"}}` ~ "\n", f);
    fclose(f);
    // An empty transcript, and a directory named as one, hold no conversation to resume.
    char[256] empty = 0, named = 0;
    snprintf(empty.ptr, empty.length, "%s/-Users-u-repo/e0e0e0e0-0000-0000-0000-000000000000.jsonl", base.ptr);
    snprintf(named.ptr, named.length, "%s/-Users-u-repo/d1d1d1d1-0000-0000-0000-000000000000.jsonl", base.ptr);
    fclose(fopen(empty.ptr, "w"));
    assert(mkdir(named.ptr, 493) == 0);
    scope(exit) { unlink(file.ptr); unlink(empty.ptr); rmdir(named.ptr); rmdir(dir.ptr); rmdir(base.ptr); }
    assert(!transcriptStands(base[0 .. n], "e0e0e0e0-0000-0000-0000-000000000000"), "an empty transcript is no conversation");
    assert(!transcriptStands(base[0 .. n], "d1d1d1d1-0000-0000-0000-000000000000"), "a directory is no transcript");

    assert(transcriptStands(base[0 .. n], "05cf89a6-7fcb-41c9-b8cb-c38f12ab8f8f"));
    assert(!transcriptStands(base[0 .. n], "27c94e9d-584e-4dea-b3e0-33428b8fc939"), "no transcript, no resume");
    assert(!transcriptStands(base[0 .. n], ""), "no session, no resume");
    assert(!transcriptStands(base[0 .. n], "../x"), "an id that climbs is no session");
    assert(!transcriptStands("/nonexistent/projects", "05cf89a6-7fcb-41c9-b8cb-c38f12ab8f8f"));
}
