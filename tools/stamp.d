/// 「[Opus 5.5] stamp — what wind stamps beside .version for the commit an engine names.」
module stamp;

/// 「[Opus 5.5] .rev's text: HEAD's whole id and a newline in a repository, nothing in a tree that is none.」
/// 「[Opus 5.5] A .rev a tree was copied with is not its commit, so it is never kept.」
string revStamp(bool repository, const(char)[] head) {
    if (!repository || head is null) return "";
    return head.idup ~ "\n";
}
