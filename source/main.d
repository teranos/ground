module main;

import core.stdc.stdio : stderr, fputs;
import hookrun : argLen, printVersion;

extern (C) int main(int argc, const(char)** argv) {
    // CLI subcommand dispatch — ground shovel <event> <pattern>
    if (argc >= 2) {
        import shovel : handleShovel;
        const(char)[] cmd = argv[1][0 .. argLen(argv[1])];
        if (cmd == "shovel")
            return handleShovel(argc, argv);
        if (cmd == "attest") {
            import attest : handleAttest;
            return handleAttest();
        }
        if (cmd == "profile") {
            import profile : handleProfile;
            return handleProfile(argc, argv);
        }
        if (cmd == "ritual") {
            import ritual : handleRitual;
            return handleRitual(argc, argv);
        }
        if (cmd == "abort") {
            import ritual : handleAbort;
            return handleAbort(argc, argv);
        }
        if (cmd == "bind") {
            import ritual : handleBind;
            return handleBind(argc, argv);
        }
        if (cmd == "events") {
            import events : handleEvents;
            return handleEvents();
        }
        if (cmd == "fmt") {
            import fmtcmd : handleFmt;
            return handleFmt(argc, argv);
        }
        if (cmd == "author") {
            import author : handleAuthor;
            return handleAuthor();
        }
        if (cmd == "usage") {
            import usagecmd : handleUsage;
            return handleUsage();
        }
        if (cmd == "ctfe") {
            import ctfe : handleCtfe;
            return handleCtfe(argc, argv);
        }
        if (cmd == "mcp") {
            import mcpcmd : handleMcp;
            return handleMcp(argc, argv);
        }
        if (cmd == "scrub") {
            import scrubcmd : handleScrub;
            return handleScrub();
        }
        if (cmd == "decay") {
            import decay : decayDb;
            import db : openDb, sqlite3_close;
            auto db = openDb();
            if (db is null) { fputs("ground decay: cannot open db\n", stderr); return 1; }
            auto rc = decayDb(db);
            sqlite3_close(db);
            return rc;
        }
    }

    printVersion();
    fputs(" — Ground Control for Agentic AI\n", stderr);
    return 0;
}
