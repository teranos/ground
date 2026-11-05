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
    fclose(f);
    scope(exit) { unlink(file.ptr); rmdir(dir.ptr); rmdir(base.ptr); }

    assert(transcriptStands(base[0 .. n], "05cf89a6-7fcb-41c9-b8cb-c38f12ab8f8f"));
    assert(!transcriptStands(base[0 .. n], "27c94e9d-584e-4dea-b3e0-33428b8fc939"), "no transcript, no resume");
    assert(!transcriptStands(base[0 .. n], ""), "no session, no resume");
    assert(!transcriptStands(base[0 .. n], "../x"), "an id that climbs is no session");
    assert(!transcriptStands("/nonexistent/projects", "05cf89a6-7fcb-41c9-b8cb-c38f12ab8f8f"));
}
