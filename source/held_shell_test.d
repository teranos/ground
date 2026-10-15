module held_shell_test;

// "One nix shell held across a ritual's rites, re-entered only when flake.nix or flake.lock changed."

import ritual.shell : enterScript, forgetScript, mustEnter, flakeKey, heldKey, holdKey;

// Entered the way ground's own Makefile holds its toolchain: --profile roots
// what the shell points at, so a garbage collection cannot take it mid-ritual.
enum entered = enterScript("/t/QNTX", "/s/shell/q-deploy-1");
static assert(entered.text() ==
    "#!/usr/bin/env bash\nset -euo pipefail\ncd '/t/QNTX' || exit 125\n"
    ~ "nix print-dev-env --profile '/s/shell/q-deploy-1' > '/s/shell/q-deploy-1.sh.new'\n"
    ~ "mv '/s/shell/q-deploy-1.sh.new' '/s/shell/q-deploy-1.sh'\n"
    ~ "env -0 > '/s/shell/q-deploy-1.before'\n"
    ~ "source '/s/shell/q-deploy-1.sh'\n"
    ~ "env -0 > '/s/shell/q-deploy-1.after'\n");

// The session's commands run in zsh, which stops at line 32 of what
// print-dev-env writes, before PATH is set:
// "read-only variable: LINENO"
// What the session sources is what the shell changed, as plain exports.
import ritual.shell : envLines, EnvLines;
enum changed = envLines("HOME=/u\0PATH=/bin\0_=/x\0", "HOME=/u\0PATH=/nix/a:/bin\0IN_NIX_SHELL=impure\0_=/y\0");
static assert(changed.text() == "export PATH='/nix/a:/bin'\nexport IN_NIX_SHELL='impure'\n");
static assert(!changed.over);

// A quote in a value stays inside the value.
enum quoting = envLines("", "shellHook=echo 'hi'\0");
static assert(quoting.text() == "export shellHook='echo '\\''hi'\\'''\n");

// A name a shell could not assign is not written.
enum odd = envLines("", "BASH_FUNC_x%%=() { :; }\0OK=1\0");
static assert(odd.text() == "export OK='1'\n");

// The performance over, its shell and the store paths it roots go with it.
enum forgotten = forgetScript("/s/shell/q-deploy-1");
static assert(forgotten.text() ==
    "#!/usr/bin/env bash\nset -euo pipefail\n"
    ~ "rm -f '/s/shell/q-deploy-1' '/s/shell/q-deploy-1'-*-link '/s/shell/q-deploy-1.sh' '/s/shell/q-deploy-1.key'"
    ~ " '/s/shell/q-deploy-1.env' '/s/shell/q-deploy-1.before' '/s/shell/q-deploy-1.after'\n");

// The session's own Bash commands source the same script. Claude Code runs the
// env file before each command, so a re-entry reaches the session too.
import ritual.shell : sessionLine;
enum line = sessionLine("/s/shell/q-deploy-1");
static assert(line.text() == "source '/s/shell/q-deploy-1.env'\n");

// Never entered: enter.
static assert(mustEnter(0, 7, false));
// flake.nix and flake.lock as they were: the held shell stands.
static assert(!mustEnter(7, 7, true));
// Either one changed: entered again.
static assert(mustEnter(7, 8, true));
// The held script is gone: there is nothing to source.
static assert(mustEnter(7, 7, false));

version (unittest)
private void writeFile(const(char)[] dir, const(char)[] leaf, const(char)[] text) {
    import core.stdc.stdio : fopen, fwrite, fclose;
    import db : ZBuf;
    __gshared ZBuf p;
    p.reset();
    p.put(dir);
    p.put(leaf);
    auto f = fopen(p.ptr(), "w");
    assert(f !is null);
    fwrite(text.ptr, 1, text.length, f);
    fclose(f);
}

version (unittest)
private void removeFile(const(char)[] dir, const(char)[] leaf) {
    import core.stdc.stdio : remove;
    import db : ZBuf;
    __gshared ZBuf p;
    p.reset();
    p.put(dir);
    p.put(leaf);
    remove(p.ptr());
}

unittest {
    import db : storeDir, mkdirP, ZBuf;
    __gshared ZBuf dir;
    dir.reset();
    dir.put(storeDir());
    dir.put("/held-shell-key");
    auto d = dir.slice();
    mkdirP(d);

    removeFile(d, "/flake.nix");
    removeFile(d, "/flake.lock");
    assert(flakeKey(d) == 0, "no flake.nix, no shell to hold");

    writeFile(d, "/flake.nix", "{ outputs = _: {}; }");
    auto onlyNix = flakeKey(d);
    assert(onlyNix != 0);

    writeFile(d, "/flake.lock", `{"nodes":{}}`);
    auto both = flakeKey(d);
    assert(both != onlyNix, "flake.lock is half of the key");
    assert(flakeKey(d) == both, "the same two files are the same key");

    writeFile(d, "/main.go", "package main");
    assert(flakeKey(d) == both, "nothing but flake.nix and flake.lock moves it");

    writeFile(d, "/flake.lock", `{"nodes":{"nixpkgs":{}}}`);
    assert(flakeKey(d) != both, "a changed lock is a changed key");
}

unittest {
    import db : storeDir, ZBuf;
    __gshared ZBuf p;
    p.reset();
    p.put(storeDir());
    p.put("/held-shell-roundtrip");
    auto profile = p.slice();

    holdKey(profile, 0);
    assert(heldKey(profile) == 0);
    holdKey(profile, 18_446_744_073_709_551_557UL);
    assert(heldKey(profile) == 18_446_744_073_709_551_557UL, "the whole 64 bits come back");
}
