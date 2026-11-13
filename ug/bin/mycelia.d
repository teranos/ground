module bin.mycelia;

// "so, why would the part that asks the node, not be able to be its own tiny binary"
import mycelia : myceliaMain;

extern (C) int main() {
    import core.stdc.stdlib : getenv;
    auto h = getenv("HOME\0".ptr);
    size_t hl = 0;
    if (h !is null) while (h[hl] != 0) hl++;
    return myceliaMain(h[0 .. hl]);
}
