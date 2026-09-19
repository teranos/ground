module backend;

// "no double or split config, they all need to go to the same call from the same token"
// Where an attestation is posted: the one node the top-level qntx block names,
// with the token file it names. Every attestation, in a project or at the top
// level, goes there; with no node named, nothing is posted and the build says
// what would have been.

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
    PostingList!(PR.init.attestations.length) r;
    if (parsed.qntx.url.length == 0) return r;
    foreach (j; 0 .. parsed.attestationCount) {
        auto a = parsed.attestations[j];
        r.items[r.len] = Posting(parsed.qntx.url, parsed.qntx.token, a.subject, j);
        r.len++;
    }
    return r;
}

// The first attestation written with no node to go to, or empty. Such a one
// would be posted nowhere, and silence is not delivery.
string unbacked(PR)(const PR parsed) {
    if (parsed.qntx.url.length > 0 || parsed.attestationCount == 0) return "";
    return parsed.attestations[0].subject;
}
