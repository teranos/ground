module ground_code;

// "similarily i want ground code to be split off from the hooks as well"
import code : handleCode;

// A D main, so the D runtime is started: ground code is not -betterC.
// `ground_code login` is the terminal auth method a client runs; with no
// arguments it speaks ACP on stdin and stdout.
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

// Signs in to the node the qntx block names, the token kept in the file the
// block names for it, where ground code and every other ground read it.
int signIn() {
    import code.login : login;
    import controls : qntxNode;
    import attest : qntxTokenFile;
    import errors : getenv;
    import core.stdc.stdio : fwrite, fflush, stdout;
    void say(const(char)[] s) { fwrite(s.ptr, 1, s.length, stdout); fflush(stdout); }
    auto status = login(qntxNode.url, qntxTokenFile(qntxNode.token), &say);
    if (status == 0 && qntxNode.token.length == 0 && getenv("QNTX_TOKEN\0".ptr) !is null)
        say("QNTX_TOKEN is set in this environment, and is read before that file.\n");
    return status;
}
