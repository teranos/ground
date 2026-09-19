module backend;

// Where an attestation is posted. A project names its backend with qntx:; an
// attestation inside the project goes there and nowhere else, and one at the
// top level goes to every backend named anywhere.

// "no double or split config, they all need to go to the same call from the same token"
// The token travels with the url: the path the project's qntx block names, or
// empty for the one ground attest always read (QNTX_TOKEN, ~/.qntx/token).
struct Posting {
    string url;
    string token;
    string subject;
    size_t attestation; // index into the parsed attestations
}

struct PostingList(size_t N) {
    Posting[N] items;
    size_t len;
}

auto postings(PR)(const PR parsed) {
    PostingList!(PR.init.projects.length * PR.init.attestations.length) r;
    foreach (i; 0 .. parsed.projectCount) {
        auto p = parsed.projects[i];
        if (p.qntx.length == 0) continue;
        foreach (j; 0 .. parsed.attestationCount) {
            auto a = parsed.attestations[j];
            if (a.project.length > 0 && a.project != p.path) continue;
            r.items[r.len] = Posting(p.qntx, p.qntxBlock.token, a.subject, j);
            r.len++;
        }
    }
    return r;
}

// The first attestation written inside a project that names no backend, or
// empty. Such a one would be posted nowhere, and silence is not delivery.
string unbacked(PR)(const PR parsed) {
    foreach (j; 0 .. parsed.attestationCount) {
        auto a = parsed.attestations[j];
        if (a.project.length == 0) continue;
        bool backed = false;
        foreach (i; 0 .. parsed.projectCount)
            if (parsed.projects[i].path == a.project && parsed.projects[i].qntx.length > 0)
                backed = true;
        if (!backed) return a.subject;
    }
    return "";
}
