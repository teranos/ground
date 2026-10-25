module shellwrite_test;

// #102: the quote controls read only Write and Edit, so a file written
// through the shell passed all three with nothing said.

import shellwrite : shellWrite;

// The issue's own repro: a printf redirected into a file.
static assert(() {
    char[256] b;
    auto w = shellWrite(`printf 'The user said "seal works" when asked about penguins.\n' > TEST.md`, b[]);
    return w.ok && w.path == "TEST.md" && w.text == "The user said \"seal works\" when asked about penguins.\n";
}());

// echo, double quotes unescaped, appended.
static assert(() {
    char[256] b;
    auto w = shellWrite(`echo "a \"quoted\" word" >> notes.md`, b[]);
    return w.ok && w.path == "notes.md" && w.text == "a \"quoted\" word";
}());

// A heredoc into a file: the body is what is written.
static assert(() {
    char[256] b;
    auto w = shellWrite("cat > doc.md <<'EOF'\nline one\nline \"two\"\nEOF", b[]);
    return w.ok && w.path == "doc.md" && w.text == "line one\nline \"two\"";
}());
static assert(() {
    char[256] b;
    auto w = shellWrite("tee out.txt <<EOF\nbody\nEOF", b[]);
    return w.ok && w.path == "out.txt" && w.text == "body";
}());

// What writes no file is no write.
static assert(() {
    char[256] b;
    return !shellWrite(`ls -la`, b[]).ok
        && !shellWrite(`make test > /dev/null 2>&1`, b[]).ok
        && !shellWrite(`echo hi 2>&1`, b[]).ok
        && !shellWrite("cat <<EOF | sort\nb\na\nEOF", b[]).ok;
}());
