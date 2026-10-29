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

// Signs in to q, the node a prompt goes through and the one that owns auth, and keeps its token in
// ~/.qntx/token. The block's url and token file are the hooks' node for attestations, k, and stay its.
int signIn() {
    import code.login : login;
    import controls : qntxNode;
    import attest : qntxTokenFile;
    import errors : getenv;
    import core.stdc.stdio : fwrite, fflush, stdout;
    void say(const(char)[] s) { fwrite(s.ptr, 1, s.length, stdout); fflush(stdout); }
    auto status = login(qntxNode.gateway.length > 0 ? qntxNode.gateway : qntxNode.url, qntxTokenFile(""), &say);
    if (status == 0 && getenv("QNTX_TOKEN\0".ptr) !is null)
        say("QNTX_TOKEN is set in this environment, and is read before that file.\n");
    return status;
}
