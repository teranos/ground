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
    buf.put(" this session. Use the Read tool before making claims about file contents.");
    return buf;
}
