module strop_test;

import strop : matchLiteral, matchLetters, matchDigits, matchOneof, matchAny,
               Part, PartKind, matchSequence, Strop, matchStrop, extractFlag,
               letters, digits, literal, any, oneof, sequence, strop,
               parseStropBlock, stropDispatch;
import hooks : Control, cmd;
import proto : parseControl, ParsedControl, parsePbt, buildScopes, ParseResult;

// Test 1: literal ": " matches at start of ": hello" — consumes 2 chars.
static assert(matchLiteral(": ", ": hello", 0).ok == true);
static assert(matchLiteral(": ", ": hello", 0).consumed == 2);

// Test 2: literal ": " doesn't match "hello" — no consumption.
static assert(matchLiteral(": ", "hello", 0).ok == false);
static assert(matchLiteral(": ", "hello", 0).consumed == 0);

// Test 3: letters(1..2) matches one uppercase letter "O" — consumed 1.
static assert(matchLetters(1, 2, "O", 0).ok == true);
static assert(matchLetters(1, 2, "O", 0).consumed == 1);

// Test 4: letters(1..2) on "O3" stops at digit — consumed 1.
static assert(matchLetters(1, 2, "O3", 0).ok == true);
static assert(matchLetters(1, 2, "O3", 0).consumed == 1);

// Test 5: letters(1..2) fails on "3O" — no leading letter.
static assert(matchLetters(1, 2, "3O", 0).ok == false);
static assert(matchLetters(1, 2, "3O", 0).consumed == 0);

// Test 6: letters(1..2) on "ABC" stops at max — consumed 2.
static assert(matchLetters(1, 2, "ABC", 0).ok == true);
static assert(matchLetters(1, 2, "ABC", 0).consumed == 2);

// Test 7: digits(1..3) matches "3" — consumed 1.
static assert(matchDigits(1, 3, "3", 0).ok == true);
static assert(matchDigits(1, 3, "3", 0).consumed == 1);

// Test 8: digits(1..3) matches "42" — consumed 2.
static assert(matchDigits(1, 3, "42", 0).ok == true);
static assert(matchDigits(1, 3, "42", 0).consumed == 2);

// Test 9: digits(1..3) fails on "" — no digit.
static assert(matchDigits(1, 3, "", 0).ok == false);
static assert(matchDigits(1, 3, "", 0).consumed == 0);

// Test 10: oneof(["DEP","DOCFIX"]) matches "DEPabc" — consumed 3.
static assert(matchOneof(["DEP", "DOCFIX"], "DEPabc", 0).ok == true);
static assert(matchOneof(["DEP", "DOCFIX"], "DEPabc", 0).consumed == 3);

// Test 11: any(80) matches "hello" — consumed 5.
static assert(matchAny(80, "hello", 0).ok == true);
static assert(matchAny(80, "hello", 0).consumed == 5);

// Test 12: any(3) fails on "abcdef" — first line exceeds max.
static assert(matchAny(3, "abcdef", 0).ok == false);
static assert(matchAny(3, "abcdef", 0).consumed == 0);

// Test 13: sequence [letters(1..2), digits(1..3), literal(": ")] matches "O3: text" — consumed 4.
enum sliceCode = [letters(1, 2), digits(1, 3), literal(": ")];
static assert(matchSequence(sliceCode, "O3: text", 0).ok == true);
static assert(matchSequence(sliceCode, "O3: text", 0).consumed == 4);

// Test 14: same sequence fails on "3O: text" — no leading letter.
static assert(matchSequence(sliceCode, "3O: text", 0).ok == false);
static assert(matchSequence(sliceCode, "3O: text", 0).consumed == 0);

// Test 15: sequence with Oneof — [oneof([DEP,DOCFIX,FIX,TIDY]), literal(": ")] matches "DEP: foo".
enum wordCode = [oneof(["DEP", "DOCFIX", "FIX", "TIDY"]), literal(": ")];
static assert(matchSequence(wordCode, "DEP: foo", 0).ok == true);
static assert(matchSequence(wordCode, "DEP: foo", 0).consumed == 5);

// Test 16: strop with sliceCode + wordCode accepts "O3: text" (slice branch).
enum commitStrop = strop([sequence(sliceCode), sequence(wordCode)]);
static assert(matchStrop(commitStrop, "O3: text").ok == true);

// Test 17: same strop accepts "DEP: foo" (word branch).
static assert(matchStrop(commitStrop, "DEP: foo").ok == true);

// Test 18: same strop rejects "hello" — matches neither.
static assert(matchStrop(commitStrop, "hello").ok == false);

// Test 19: extract -m value with double quotes.
static assert(extractFlag(`git commit -m "hello world"`, "-m").ok == true);
static assert(extractFlag(`git commit -m "hello world"`, "-m").value == "hello world");

// Test 20: extract -m value bare (no quotes, no spaces).
static assert(extractFlag(`git commit -m hello`, "-m").ok == true);
static assert(extractFlag(`git commit -m hello`, "-m").value == "hello");

// Test 21: extract -m value with single quotes.
static assert(extractFlag(`git commit -m 'hello'`, "-m").ok == true);
static assert(extractFlag(`git commit -m 'hello'`, "-m").value == "hello");

// Test 22: no -m present — not found.
static assert(extractFlag(`git commit`, "-m").ok == false);

// Test 23: strop builder yields two sequences.
static assert(strop([sequence(sliceCode), sequence(wordCode)]).sequenceCount == 2);

// Test 24: Strop carries a flag identifier.
enum stropWithFlag = () { Strop s; s.flag = "-m"; return s; }();
static assert(stropWithFlag.flag == "-m");

// Test 25: parseStropBlock reads flag from a snippet ending with '}'.
enum parsedFlag = () {
    string s = "flag: \"-m\"\n}";
    size_t pos = 0;
    return parseStropBlock(s, pos).flag;
}();
static assert(parsedFlag == "-m");

// Test 26: parseStropBlock reads sequence [ letters(1..2) ].
enum parsedSeq26 = () {
    string s = "sequence [ letters(1..2) ]\n}";
    size_t pos = 0;
    return parseStropBlock(s, pos);
}();
static assert(parsedSeq26.sequenceCount == 1);
static assert(parsedSeq26.sequences[0].partCount == 1);
static assert(parsedSeq26.sequences[0].parts[0].kind == PartKind.Letters);
static assert(parsedSeq26.sequences[0].parts[0].min == 1);
static assert(parsedSeq26.sequences[0].parts[0].max == 2);

// Test 27: digits part.
enum parsed27 = () {
    string s = "sequence [ digits(1..3) ]\n}";
    size_t pos = 0;
    return parseStropBlock(s, pos);
}();
static assert(parsed27.sequences[0].parts[0].kind == PartKind.Digits);
static assert(parsed27.sequences[0].parts[0].min == 1);
static assert(parsed27.sequences[0].parts[0].max == 3);

// Test 28: literal part.
enum parsed28 = () {
    string s = "sequence [ literal(\": \") ]\n}";
    size_t pos = 0;
    return parseStropBlock(s, pos);
}();
static assert(parsed28.sequences[0].parts[0].kind == PartKind.Literal);
static assert(parsed28.sequences[0].parts[0].literal == ": ");

// Test 29: any(max: N) part.
enum parsed29 = () {
    string s = "sequence [ any(max: 80) ]\n}";
    size_t pos = 0;
    return parseStropBlock(s, pos);
}();
static assert(parsed29.sequences[0].parts[0].kind == PartKind.Any);
static assert(parsed29.sequences[0].parts[0].max == 80);

// Test 30: oneof([DEP, DOCFIX, FIX, TIDY]) part.
enum parsed30 = () {
    string s = "sequence [ oneof([DEP, DOCFIX, FIX, TIDY]) ]\n}";
    size_t pos = 0;
    return parseStropBlock(s, pos);
}();
static assert(parsed30.sequences[0].parts[0].kind == PartKind.Oneof);
static assert(parsed30.sequences[0].parts[0].wordCount == 4);
static assert(parsed30.sequences[0].parts[0].words[0] == "DEP");
static assert(parsed30.sequences[0].parts[0].words[1] == "DOCFIX");
static assert(parsed30.sequences[0].parts[0].words[2] == "FIX");
static assert(parsed30.sequences[0].parts[0].words[3] == "TIDY");

// Test 31: multi-sequence strop.
enum parsed31 = () {
    string s = "sequence [ letters(1..2) digits(1..3) literal(\": \") ] sequence [ oneof([DEP, FIX]) literal(\": \") ]\n}";
    size_t pos = 0;
    return parseStropBlock(s, pos);
}();
static assert(parsed31.sequenceCount == 2);
static assert(parsed31.sequences[0].partCount == 3);
static assert(parsed31.sequences[1].partCount == 2);

// Test 32: parseControl reads a control body with strop { flag: "-m" }.
// After the pointer refactor, ParsedControl carries only stropIdx (1-based index
// into the enclosing ParseResult.stropPool). We surface the parsed flag from the
// pool for the assertion.
struct T32 { string name; size_t stropIdx; string stropFlag; }
enum parsed32 = () {
    string s = "name: \"test-strop\"\nstrop {\nflag: \"-m\"\n}\n}";
    size_t pos = 0;
    ParseResult pr;
    ParsedControl pc = parseControl(s, pos, pr);
    T32 r;
    r.name = pc.name;
    r.stropIdx = pc.stropIdx;
    if (pc.stropIdx > 0) r.stropFlag = pr.stropPool[pc.stropIdx - 1].flag;
    return r;
}();
static assert(parsed32.name == "test-strop");
static assert(parsed32.stropIdx == 1);
static assert(parsed32.stropFlag == "-m");

// Test 33: stropDispatch allows well-formed input.
enum stropOk = () {
    Strop s;
    s.flag = "-m";
    s.sequences[0] = sequence(sliceCode);
    s.sequences[1] = sequence(wordCode);
    s.sequenceCount = 2;
    return stropDispatch(s, `git commit -m "O3: fix"`);
}();
static assert(stropOk.deny == false);

// Test 34: stropDispatch denies mismatched input.
enum stropDeny = () {
    Strop s;
    s.flag = "-m";
    s.sequences[0] = sequence(sliceCode);
    s.sequences[1] = sequence(wordCode);
    s.sequenceCount = 2;
    return stropDispatch(s, `git commit -m "hello world"`);
}();
static assert(stropDeny.deny == true);
static assert(stropDeny.msg.length > 0);

// Test 35: stropDispatch on cmd with no matching flag — deny (rule not verifiable, better to reject).
enum stropNoFlag = () {
    Strop s;
    s.flag = "-m";
    s.sequences[0] = sequence(sliceCode);
    s.sequenceCount = 1;
    return stropDispatch(s, `git commit`);
}();
static assert(stropNoFlag.deny == true);

// Test 36: shape-mismatch msg includes the offending value.
enum stropRichMsg = () {
    Strop s;
    s.flag = "-m";
    s.sequences[0] = sequence(sliceCode);
    s.sequenceCount = 1;
    return stropDispatch(s, `git commit -m "hello world"`);
}();
static assert(stropRichMsg.deny == true);
// msg must contain the offending value "hello world" so the user sees what they submitted.
static assert({
    string hay = stropRichMsg.msg;
    string needle = "hello world";
    if (needle.length > hay.length) return false;
    foreach (i; 0 .. hay.length - needle.length + 1) {
        bool ok = true;
        foreach (j; 0 .. needle.length) if (hay[i+j] != needle[j]) { ok = false; break; }
        if (ok) return true;
    }
    return false;
}());

// Test 37: End-to-end pbt → parsePbt → buildScopes → Control has strop populated + cmd inherited.
enum e2eFixture = `scope {
  event: "PreToolUse"
  cmd: "git commit"
  path: "/teranos/ground"

  control {
    name: "e2e-strop"
    strop {
      flag: "-m"
      sequence [
        oneof([DEP, DOCFIX, FIX, TIDY, WIP])
        literal(": ")
      ]
    }
  }
}
`;
// Assertion data lifted from the full ParseResult+ScopeSet into a small struct
// so the enum only materializes the fields we assert on (avoids CTFE bloat from
// the whole ParseResult being stored as compile-time data).
struct T37 {
    size_t scopeCount;
    size_t controlCount;
    string controlName;
    size_t stropIdx;
    string stropFlag;
    ubyte stropSeqCount;
    string cmdVal;
}
enum e2eSummary = () {
    ParseResult pr = parsePbt(e2eFixture);
    auto ss = buildScopes(pr, "PreToolUse");
    T37 r;
    r.scopeCount = ss.len;
    if (ss.len > 0) {
        r.controlCount = ss.items[0].controls.length;
        if (r.controlCount > 0) {
            r.controlName = ss.items[0].controls[0].name;
            r.stropIdx = ss.items[0].controls[0].stropIdx;
            r.cmdVal = ss.items[0].controls[0].cmd.value;
            if (r.stropIdx > 0) {
                r.stropFlag = pr.stropPool[r.stropIdx - 1].flag;
                r.stropSeqCount = pr.stropPool[r.stropIdx - 1].sequenceCount;
            }
        }
    }
    return r;
}();
static assert(e2eSummary.scopeCount == 1);                    // scope built
static assert(e2eSummary.controlCount == 1);                  // one control in scope
static assert(e2eSummary.controlName == "e2e-strop");         // control name preserved
static assert(e2eSummary.stropIdx == 1);                      // strop was assigned an index
static assert(e2eSummary.stropFlag == "-m");                  // strop flag reachable via pool
static assert(e2eSummary.stropSeqCount == 1);                 // one sequence in the strop
static assert(e2eSummary.cmdVal == "git commit");             // cmd inherited from scope
