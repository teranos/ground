module sessionmode;

/// https://code.claude.com/docs/en/permission-modes
enum SessionMode {
    unknown,
    manual,
    plan,
    acceptEdits,
    auto_,
    dontAsk,
    bypassPermissions,
}

SessionMode parseSessionMode(const(char)[] wire) {
    if (wire == "default") return SessionMode.manual;
    if (wire == "plan") return SessionMode.plan;
    if (wire == "acceptEdits") return SessionMode.acceptEdits;
    if (wire == "auto") return SessionMode.auto_;
    if (wire == "dontAsk") return SessionMode.dontAsk;
    if (wire == "bypassPermissions") return SessionMode.bypassPermissions;
    return SessionMode.unknown;
}

bool grants(SessionMode m) {
    return m != SessionMode.manual && m != SessionMode.unknown;
}

char letterOf(SessionMode m) {
    final switch (m) {
        case SessionMode.manual: return 'm';
        case SessionMode.plan: return 'p';
        case SessionMode.acceptEdits: return 'a';
        case SessionMode.auto_: return 'a';
        case SessionMode.dontAsk: return 'd';
        case SessionMode.bypassPermissions: return 'b';
        case SessionMode.unknown: return '\0';
    }
}

const(char)[] nameOf(SessionMode m) {
    final switch (m) {
        case SessionMode.manual: return "default";
        case SessionMode.plan: return "plan";
        case SessionMode.acceptEdits: return "acceptEdits";
        case SessionMode.auto_: return "auto";
        case SessionMode.dontAsk: return "dontAsk";
        case SessionMode.bypassPermissions: return "bypassPermissions";
        case SessionMode.unknown: return "";
    }
}
