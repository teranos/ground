module attest;

import core.stdc.stdio : stderr, fputs, fwrite, fprintf;
import db : ZBuf;

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

            import http : httpPost;
            auto code = httpPost(url.slice(), body_.slice(), 400);

            // Report
            fputs("  ", stderr);
            fputs2(node.url);
            fputs(" ", stderr);
            fputs2(a.subject);
            fputs(" -> ", stderr);
            if (code >= 200 && code < 300) {
                fprintf(stderr, "%d ok\n".ptr, code);
                posted++;
            } else if (code == 0) {
                fputs("unreachable\n", stderr);
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
