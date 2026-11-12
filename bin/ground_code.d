module ground_code;

// "similarily i want ground code to be split off from the hooks as well"
import code : handleCode;

// 「[Opus 5.5] A D main, so the D runtime is started: ground code is not -betterC.」
// 「[Opus 5.5] `ground_code login` is the terminal auth method a client runs; with no」
// 「[Opus 5.5] arguments it speaks ACP on stdin and stdout.」
int main(string[] args) {
    if (args.length == 2 && args[1] == "login") return signIn();
    if (args.length > 1) {
        import core.stdc.stdio : fputs, stderr;
        fputs("usage: ground_code         speak ACP on stdin and stdout\n"
            ~ "       ground_code login   sign in to the qntx block's node\n", stderr);
        return 2;
    }
    return handleCode();
}

// Signs in to q, the node a prompt goes through and the one that owns auth, as
// 「[Opus 5.5] the key kept in ~/.qntx/key.」
//
// "A signature proves the key, and nothing reusable leaves the node."
int signIn() {
    import code.login : login;
    import code.node : qntxNode;
    import signed : keyFile;
    import core.stdc.stdio : fwrite, fflush, stdout;
    void say(const(char)[] s) { fwrite(s.ptr, 1, s.length, stdout); fflush(stdout); }
    return login(qntxNode.gateway.length > 0 ? qntxNode.gateway : qntxNode.url, keyFile(), &say);
}
