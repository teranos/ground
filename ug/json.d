module json;

// Just enough of the session JSON to name a segment. The row needs a handful
// of string fields and nothing else, so nothing else is parsed.

// The value of a top-level-or-nested string field, as a slice of the input.
// Null when the key is absent, so an absent field is a segment that does not
// draw rather than an empty one that does.
const(char)[] jsonString(const(char)[] input, const(char)[] key) {
    // The key is a quoted name followed by a colon, so a bare occurrence
    // inside a value never matches.
    auto j = valueStart(input, key);
    if (j >= input.length || input[j] != '"') return null;

    size_t start = j + 1;
    size_t end = start;
    while (end < input.length && input[end] != '"') {
        if (input[end] == '\\' && end + 1 < input.length) end++;
        end++;
    }
    return input[start .. end];
}

// A numeric field, truncated to a whole number. Negative one when the key is
// absent, which is how a segment decides not to draw.
int jsonNumber(const(char)[] input, const(char)[] key) {
    auto at = valueStart(input, key);
    if (at >= input.length) return -1;
    if (input[at] < '0' || input[at] > '9') return -1;

    int v = 0;
    auto i = at;
    while (i < input.length && input[i] >= '0' && input[i] <= '9') {
        v = v * 10 + (input[i] - '0');
        i++;
    }
    return v;
}

// Where a key's value begins, past the colon and any spaces. The input's own
// length when the key is not there.
private size_t valueStart(const(char)[] input, const(char)[] key) {
    if (key.length == 0) return input.length;

    size_t i = 0;
    while (i + key.length + 3 < input.length) {
        if (input[i] != '"') { i++; continue; }
        if (input[i + 1 .. i + 1 + key.length] != key) { i++; continue; }
        if (input[i + 1 + key.length] != '"') { i++; continue; }

        size_t j = i + 2 + key.length;
        while (j < input.length && (input[j] == ' ' || input[j] == '\t')) j++;
        if (j >= input.length || input[j] != ':') { i++; continue; }

        j++;
        while (j < input.length && (input[j] == ' ' || input[j] == '\t')) j++;
        return j;
    }
    return input.length;
}

// The last element of a path, which is what a repository is called.
const(char)[] baseName(const(char)[] path) {
    size_t end = path.length;
    while (end > 0 && path[end - 1] == '/') end--;
    if (end == 0) return null;

    size_t start = end;
    while (start > 0 && path[start - 1] != '/') start--;
    return path[start .. end];
}
