module messagedisplay_test;

import messagedisplay;
import db : ZBuf;

// "  ░▓▓▏[REPONAME] [BRANCHNAME] ci all checks passed ✓"
// "   ░░▏Nix / build-go (linux-latest, goat_binary) (pull_request) Successful in 8m"
static assert(CI_GUTTER == "  ░▓▓▏");
static assert(CHECK_GUTTER == "   ░░▏");

// The existing two are unchanged.
static assert(RITE_GUTTER == "  ░░▏");
static assert(RITUAL_GUTTER == "░░▒▓▏");

// A CI line is not a rite line. The key says which.
static assert(gutterFor("immediate:note:sess:ci:moon-1786212018:JUDGE") == CI_GUTTER);
static assert(gutterFor("immediate:note:sess:rite:moon-1786212018:JUDGE") == RITE_GUTTER);
static assert(gutterFor("immediate:note:sess:ritual:moon-1786212018") == RITUAL_GUTTER);

unittest {
    // One mark for the head, another for everything under it.
    ZBuf out_;
    out_.reset();
    gutter(out_, CI_GUTTER, CHECK_GUTTER, "grove master ci all checks passed\nshort-moon Successful in 8s");
    assert(out_.slice() ==
           "  ░▓▓▏grove master ci all checks passed\n" ~
           "   ░░▏short-moon Successful in 8s\n");
}

unittest {
    // The single-mark form still marks every line the same.
    ZBuf out_;
    out_.reset();
    gutter(out_, RITE_GUTTER, "one\ntwo");
    assert(out_.slice() == "  ░░▏one\n  ░░▏two\n");
}

unittest {
    // A rite's stdout ends in a newline. Marking the nothing after it drew a
    // bare gutter under every ci block.
    ZBuf out_;
    out_.reset();
    gutter(out_, CI_GUTTER, CHECK_GUTTER, "head\nmoon success\n");
    assert(out_.slice() == "  ░▓▓▏head\n   ░░▏moon success\n");
}

unittest {
    // The key alone decides both marks, so the caller cannot pick one and
    // forget the other — which is how the checks ended up wearing ci's mark.
    ZBuf out_;
    out_.reset();
    marked(out_, "immediate:note:s:ci:moon-1:JUDGE:22", "head\nmoon success\n");
    assert(out_.slice() == "  ░▓▓▏head\n   ░░▏moon success\n");

    out_.reset();
    marked(out_, "immediate:note:s:rite:moon-1:MOON:5", "MOON passed");
    assert(out_.slice() == "  ░░▏MOON passed\n");
}
