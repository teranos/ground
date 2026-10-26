module ground_parity;

// "and ground parity can just be ground_parity"
// A developer's tool, so the hook binary does not pay for its compile-time
// reading of the pinned agents' schemas.
import parity : handleParity;

extern (C) int main(int argc, const(char)** argv) {
    // handleParity's argv[1] is the subcommand word of the old `ground parity`.
    enum maxArgs = 8;
    const(char)*[maxArgs] shifted;
    if (argc >= maxArgs) return 2;
    shifted[0] = argv[0];
    shifted[1] = "parity";
    foreach (i; 1 .. argc) shifted[i + 1] = argv[i];
    return handleParity(argc + 1, shifted.ptr);
}
