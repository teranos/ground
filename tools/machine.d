/// machine — whether a repository's controls are a machine's.
module machine;

/// Whether pbt names the node at the top level: a qntx block starting its line, as `ground fmt`
/// lays every pbt out and code/node.d reads it. Only a machine's controls name the node.
bool namesNode(string pbt) {
    size_t line = 0;
    while (line < pbt.length) {
        auto end = line;
        while (end < pbt.length && pbt[end] != '\n') end++;
        if (end - line >= 4 && pbt[line .. line + 4] == "qntx") {
            auto p = line + 4;
            while (p < end && (pbt[p] == ' ' || pbt[p] == '\t')) p++;
            if (p < end && pbt[p] == '{') return true;
        }
        line = end + 1;
    }
    return false;
}
