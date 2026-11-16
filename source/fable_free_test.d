module fable_free_test;

// "stop Fable from editing how it likes, the rule is for semantically weaker models like Opus"
// "we dont need to block and generate expensie fable turns"
// The quote gates hold Opus to the user's words as they stand; a Fable session
// is spared them, and Opus is not.

import controls : allScopes;
import control_handlers : sparedByModel;

unittest {
    int seen = 0;
    foreach (ref sc; allScopes)
        foreach (ref c; sc.controls) {
            if (c.name != "quotes-stand-alone" && c.name != "quotes-keep-chronology") continue;
            seen++;
            assert(sparedByModel("claude-fable-5-2", c), c.name);
            assert(!sparedByModel("claude-opus-5-5", c), c.name);
        }
    assert(seen == 2, "both quote gates are in the controls");
}
