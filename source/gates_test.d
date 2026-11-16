module gates_test;

// "so there is no discussion"
// "i need to be able to say gates off"
// "and just have a model cruise"
// The latest `gates off` or `gates on` the person typed in a session decides;
// gates are on until one is said. Prompts are newest first.

import gates : gatesOffIn, isGatesOff, isGatesOn;

static assert(isGatesOff("gates off"));
static assert(isGatesOff("  Gates Off \n"));
static assert(!isGatesOff("gates off please, and then fix it"), "only the words alone");
static assert(isGatesOn("gates on"));

static assert(!gatesOffIn([]), "nothing said is gates on");
static assert(gatesOffIn(["gates off"]));
static assert(gatesOffIn(["fix the doc", "gates off"]), "it holds past later prompts");
static assert(!gatesOffIn(["gates on", "gates off"]), "the latest one said decides");
static assert(gatesOffIn(["gates off", "gates on"]));

// "can we make it somethng like a slahs command so its not spending a turn?"
// book: gates-isGatesOff
// The slash form is the same words, and either is answered by ground alone.
static assert(isGatesOff("/gates off"));
static assert(isGatesOn("/gates on"));
static assert(gatesOffIn(["/gates off"]));
static assert(!isGatesOff("/gates"), "the bare command says neither");
