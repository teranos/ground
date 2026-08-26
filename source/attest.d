module attest;

import core.stdc.stdio : stderr, fputs, fwrite, fprintf;
import db : ZBuf;

// One token. A second name for the same credential is a second thing to
// rotate, and the one nobody rotated went stale and was refused for weeks.
// What tells these attestations apart is actors ["ground"], not the filename.
private const(char)[] qntxToken() {
    import errors : getenv, open, read, close, O_RDONLY;
    import http : trimToken;

    auto env = getenv("QNTX_TOKEN\0".ptr);
    if (env !is null) {
        size_t n = 0;
        while (env[n] != 0) n++;
        auto t = trimToken(env[0 .. n]);
        if (t.length > 0) return t;
    }

    auto home = getenv("HOME\0".ptr);
    if (home is null) return null;
    size_t hLen = 0;
    while (home[hLen] != 0) hLen++;

    __gshared ZBuf pathBuf;
    pathBuf.reset();
    pathBuf.put(home[0 .. hLen]);
    pathBuf.put("/.qntx/token");

    auto fd = open(pathBuf.ptr(), O_RDONLY, 0);
    if (fd < 0) return null;
    __gshared char[512] tokBuf = 0;
    auto n = read(fd, &tokBuf[0], tokBuf.length);
    close(fd);
    if (n <= 0) return null;
    return trimToken(tokBuf[0 .. cast(size_t) n]);
}

int handleAttest() {
    import controls : qntxNodes, attestations;

    if (qntxNodes.length == 0) {
        fputs("ground attest: no qntx nodes defined\n", stderr);
        return 0;
    }
    if (attestations.length == 0) {
        fputs("ground attest: no attestations defined\n", stderr);
        return 0;
    }

    int posted = 0;
    int failed = 0;

    auto token = qntxToken();

    foreach (ref node; qntxNodes) {
        foreach (ref a; attestations) {
            __gshared ZBuf body_;
            body_.reset();
            body_.put(`{"subjects":["`);
            body_.put(a.subject);
            body_.put(`"],"predicates":["`);
            body_.put(a.predicate);
            body_.put(`"],"contexts":["`);
            body_.put(a.context);
            body_.put(`"],"actors":["ground"]`);
            if (a.attributes.length > 0) {
                body_.put(`,"attributes":`);
                body_.put(a.attributes);
            }
            body_.put(`}`);

            __gshared ZBuf url;
            url.reset();
            url.put(node.url);
            url.put("/api/attestations");

            // http:// goes over the in-process socket; anything else needs
            // DNS and TLS, which is curl's job.
            import http : httpPost, curlPost, needsCurl;
            auto remote = needsCurl(node.url);
            auto code = remote
                ? curlPost(url.slice(), body_.slice(), token)
                : httpPost(url.slice(), body_.slice(), 400);

            // Report
            fputs("  ", stderr);
            fputs2(node.url);
            fputs(" ", stderr);
            fputs2(a.subject);
            fputs(" -> ", stderr);
            if (code >= 200 && code < 300) {
                fprintf(stderr, "%d ok\n".ptr, code);
                posted++;
            } else if (code == 401 || code == 403) {
                // Naming the cause here is the difference between a fix and a
                // hunt: the endpoint answered, it just would not take us.
                fputs(token.length > 0
                    ? "401/403 — token rejected (QNTX_TOKEN or ~/.qntx/token)\n"
                    : "401/403 — no token (set QNTX_TOKEN or ~/.qntx/token)\n",
                    stderr);
                failed++;
            } else if (code == 0) {
                fputs(remote ? "unreachable (curl)\n" : "unreachable\n", stderr);
                failed++;
            } else {
                fprintf(stderr, "%d failed\n".ptr, code);
                failed++;
            }
        }
    }

    fprintf(stderr, "ground attest: %d posted, %d failed\n".ptr, posted, failed);
    return 0;
}

private void fputs2(const(char)[] s) {
    fwrite(s.ptr, 1, s.length, stderr);
}
