module unread;

import zbuf : ZBuf;

ZBuf buildUnreadClaimMessage(const(char)[][] filenames) {
    ZBuf buf;
    if (filenames.length == 0) return buf;

    buf.put("You referenced ");
    foreach (i, f; filenames) {
        if (i > 0) buf.put(", ");
        buf.putChar('`');
        buf.put(f);
        buf.putChar('`');
    }
    buf.put(" but never Read ");
    buf.put(filenames.length == 1 ? "it" : "them");
    // State the rule this control actually enforces. It matches a filename in
    // the assistant's text and checks for a Read attestation — it cannot see
    // whether a claim about contents was made, so saying "before making claims
    // about file contents" describes a narrower rule than the one being
    // applied. A reader who measures themselves against the stated rule finds
    // themselves innocent of it, calls the control a false positive, and
    // argues instead of complying. An ERROR must state what was measured.
    buf.put(" this session. Naming a file is claiming it — Read ");
    buf.put(filenames.length == 1 ? "it" : "them");
    buf.put(" in full before you mention ");
    buf.put(filenames.length == 1 ? "it" : "them");
    buf.put(", including in passing or in pasted output.");
    return buf;
}
