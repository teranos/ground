module bin.ground_tmux;

// "i see, so the tmux row, would just be named like, ground_tmux"
import tmux : tmuxMain, clickMain;

extern (C) int main(int argc, char** argv) {
    import core.stdc.stdlib : getenv;
    import core.stdc.time : time;

    auto h = getenv("HOME\0".ptr);
    size_t hl = 0;
    if (h !is null) while (h[hl] != 0) hl++;
    auto home = h[0 .. hl];

    // What tmux runs on a click, with the clicked range's name.
    if (argc >= 2 && argv[1] !is null) {
        size_t al = 0;
        while (argv[1][al] != 0) al++;
        if (argv[1][0 .. al] == "click") {
            const(char)[] which;
            if (argc >= 3 && argv[2] !is null) {
                size_t nl = 0;
                while (argv[2][nl] != 0) nl++;
                which = argv[2][0 .. nl];
            }
            return clickMain(home, which);
        }
    }
    return tmuxMain(home, cast(long) time(null));
}
