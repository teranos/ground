module userprompt_test;

import userprompt : putJsonText;
import zbuf : ZBuf;

// The timer-for control's message, as the sand holds it. Put raw, its quote
// ended additionalContext there, and the hook's answer was no JSON.
unittest {
    static ZBuf b;
    b.reset();
    putJsonText(b, `sleep <seconds> && say "time" &`);
    assert(b.slice() == `sleep <seconds> && say \"time\" &`);
}

// am-toml-read and stoke are messages of several lines; a newline is said, not dropped.
unittest {
    static ZBuf b;
    b.reset();
    putJsonText(b, "Active deployment is running on: q.abcd.nl\nmanaged by\tdeployment repo");
    assert(b.slice() == `Active deployment is running on: q.abcd.nl\nmanaged by\tdeployment repo`);
}

// A prompt's handler took 1430ms with nothing to say where; its row now names
// each step it walked.
unittest {
    import userprompt : handleUserPromptSubmit;
    import hookrun : getPhases, setPhases;
    import matcher : contains;
    setPhases("");
    handleUserPromptSubmit(`{"prompt":"hello"}`, "/nonexistent", "phases-test");
    auto p = getPhases();
    foreach (k; ["sweep", "ingest", "said", "controls", "bill"])
        assert(contains(p, k), p);
}

unittest {
    static ZBuf b;
    b.reset();
    putJsonText(b, "a \\ b\r\x01");
    assert(b.slice() == `a \\ b\r\u0001`);
}
