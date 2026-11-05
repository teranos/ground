/// stamp — what wind stamps beside .version for the commit an engine names.
module stamp;

/// .rev's text: HEAD's whole id and a newline in a repository, nothing in a tree that is none.
/// A .rev a tree was copied with is not its commit, so it is never kept.
string revStamp(bool repository, const(char)[] head) {
    if (!repository || head is null) return "";
    return head.idup ~ "\n";
}
