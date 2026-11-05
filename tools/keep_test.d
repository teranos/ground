module keep_test;

import keep : refusal, projectsOf, countRefusal;

// "make ground aget fix it"
// 「[Opus 5.5] An install from a tree without controls/local, a worktree's, put the floor where the machine's」
// 「[Opus 5.5] sand was: the owner's controls were off the laptop, and nothing said so. The sand installed says」
// 「[Opus 5.5] how many projects it folded; an install that would put none where there were some is refused.」
static assert(refusal(true, 19, 0, "/h/sand") != "");
static assert(refusal(true, 19, 0, "/h/sand") ==
    "make install refuses: this tree's sand folds 0 projects, and the sand installed at /h/sand folds 19."
    ~ " wind found no project here: controls/local is untracked, so a worktree has none."
    ~ " Install from the checkout whose controls/local declares them, or remove /h/sand to install the floor.");

// 「[Opus 5.5] No sand installed is a first install; a sand that says nothing of its projects was installed」
// 「[Opus 5.5] before they were counted; projects where there were some, more or fewer, are the operator's.」
static assert(refusal(false, -1, 0, "/h/sand") == "");
static assert(refusal(true, -1, 0, "/h/sand") == "");
static assert(refusal(true, 0, 0, "/h/sand") == "");
static assert(refusal(true, 19, 5, "/h/sand") == "");
static assert(refusal(true, 19, 19, "/h/sand") == "");

// 「[Opus 5.5] What wind writes: the count, a line. Anything else is no count.」
static assert(projectsOf("19\n") == 19);
static assert(projectsOf("0\n") == 0);
static assert(projectsOf("") == -1);
static assert(projectsOf("x\n") == -1);
static assert(projectsOf("1 9\n") == -1);

// 「[Opus 5.5] A count beside the installed sand that is no count is said, and the install stops: read as no」
// 「[Opus 5.5] count, it let a floor in where the sand it stood beside had projects.」
static assert(countRefusal(true, "x\n", "/h/sand") ==
    "make install refuses: /h/sand.projects holds no count of projects, so what the sand installed at /h/sand"
    ~ " folds is not known. Remove /h/sand.projects to install over it.");
static assert(countRefusal(true, "19\n", "/h/sand") == "");
static assert(countRefusal(false, "", "/h/sand") == "");
