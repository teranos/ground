/// sandabi — the engine ABI a sand built from this tree is for, as `make sand` writes it beside the library.
module sandabi;

// "A comet held for the harness is checked there."

import sand.view : SAND_ABI;

extern (C) int main() {
    import core.stdc.stdio : printf;
    printf("%llu\n", cast(ulong) SAND_ABI);
    return 0;
}
