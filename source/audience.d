module audience;

// BOOK_GLOSSARY **Audience**: Who gets to see what is written at a path: this machine only, or the whole internet.

import hooks : Visibility;

// "Is this piece of text going to end up somewhere the whole internet gets to
// see it? Or is it entirely fine because it's in a scratchpad or any place
// where it's not going to end up somewhere publicly"

enum Audience { Scratch, NoRepo, Ignored, Private, Public, Unknown }

// The classification from the facts, in the order they exclude each other.
Audience audienceFrom(bool scratch, bool ignored, bool inRepo, Visibility seen) {
    if (scratch) return Audience.Scratch;
    if (!inRepo) return Audience.NoRepo;
    if (ignored) return Audience.Ignored;
    final switch (seen) {
        case Visibility.Public: return Audience.Public;
        case Visibility.Private: return Audience.Private;
        case Visibility.Unknown: return Audience.Unknown;
    }
}

// The policy. Unknown is seen, because it is the case where a leak costs most.
bool internetSees(Audience a) {
    return a == Audience.Public || a == Audience.Unknown;
}

// The audience of a path. Whether git ignores the file is a subprocess, so it
// is asked only when the caller says so, once something has matched.
Audience audienceOf(const(char)[] path, bool askGit) {
    if (__ctfe) return Audience.NoRepo;
    import scratchdir : scratchHere;
    import git : repoRoot, repoVisibility, isIgnored;

    if (scratchHere(path)) return Audience.Scratch;
    auto root = repoRoot(path);
    if (root.length == 0) return Audience.NoRepo;
    if (askGit && isIgnored(root, path)) return audienceFrom(false, true, true, Visibility.Unknown);
    return audienceFrom(false, false, true, repoVisibility(root));
}
