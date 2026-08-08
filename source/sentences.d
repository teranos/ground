module sentences;

private bool isSpace(char c) {
    return c == ' ' || c == '\n' || c == '\t' || c == '\r';
}

// A terminator ends a sentence only when whitespace or the end follows it.
// Without that test the dots in a version number end three of them.
private bool endsSentence(const(char)[] s, size_t i) {
    auto c = s[i];
    if (c != '.' && c != '!' && c != '?') return false;
    return i + 1 >= s.length || isSpace(s[i + 1]);
}

// The head of what the agent said, cut to two sentences. Returns a slice of
// the input, so it carries no allocation and nothing to free.
const(char)[] firstTwoSentences(const(char)[] s) {
    size_t b;
    while (b < s.length && isSpace(s[b])) b++;

    size_t found;
    foreach (i; b .. s.length) {
        if (!endsSentence(s, i)) continue;
        found++;
        if (found == 2 || i + 1 >= s.length) return s[b .. i + 1];
    }

    // One sentence or none. Whatever is there is what was said.
    size_t e = s.length;
    while (e > b && isSpace(s[e - 1])) e--;
    return s[b .. e];
}
