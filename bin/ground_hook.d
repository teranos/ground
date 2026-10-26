module ground_hook;

// "ground_hook as the hooks binary"
import hookrun : hookMain;

extern (C) int main(int argc, const(char)** argv) {
    return hookMain(argc, argv);
}
