module bin.mycelia;

// "so, why would the part that asks the node, not be able to be its own tiny binary"
import mycelia : myceliaMain, verbOf, Verb;

// Here and not in mycelia.d, so only this binary carries the sign-in.
int connectMain() {
    import code.login : login;
    import signed : keyFile;
    import probe : host;
    import core.stdc.stdio : fwrite, fflush, stdout;
    void say(const(char)[] s) { fwrite(s.ptr, 1, s.length, stdout); fflush(stdout); }
    return login(host(), keyFile(), &say);
}

extern (C) int main(int argc, char** argv) {
    import core.stdc.stdlib : getenv;
    import core.stdc.stdio : fputs, stderr;

    const(char)[] verb;
    if (argc >= 2 && argv[1] !is null) {
        size_t al = 0;
        while (argv[1][al] != 0) al++;
        verb = argv[1][0 .. al];
    }
    final switch (verbOf(verb)) {
        case Verb.connect:
            return connectMain();
        case Verb.unknown:
            fputs("usage: mycelia           ask the node, pass after pass\n"
                ~ "       mycelia connect   sign this machine's key in to the node\n", stderr);
            return 2;
        case Verb.ask:
            auto h = getenv("HOME\0".ptr);
            size_t hl = 0;
            if (h !is null) while (h[hl] != 0) hl++;
            return myceliaMain(h[0 .. hl]);
    }
}
