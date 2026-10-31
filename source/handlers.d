module handlers;

// The engine's side of a control's handlers: the name the sand carries,
// resolved to the code that runs it.

import hooks : CheckFn, DelayFn, DeliverFn;
import handler_names : checkNames, delayNames, deliverNames;
import control_handlers;

CheckFn resolveCheck(const(char)[] name) {
    switch (name) {
        case "binaryShadowed": return &control_handlers.binaryShadowed;
        case "commitNotRequested": return &control_handlers.commitNotRequested;
        case "mergeNotRequested": return &control_handlers.mergeNotRequested;
        case "killNotRequested": return &control_handlers.killNotRequested;
        case "branchNotRequested": return &control_handlers.branchNotRequested;
        case "prNotRequested": return &control_handlers.prNotRequested;
        case "quoteProvenance": return &control_handlers.quoteProvenance;
        case "quoteStandsAlone": return &control_handlers.quoteStandsAlone;
        case "quoteChronology": return &control_handlers.quoteChronology;
        case "strikethrough": return &control_handlers.strikethroughCheck;
        case "unanalyzableBash": return &control_handlers.unanalyzableBash;
        case "deepAndChain": return &control_handlers.deepAndChain;
        case "stagedNamesPerson": return &control_handlers.stagedNamesPerson;
        case "pushNamesPerson": return &control_handlers.pushNamesPerson;
        default: return null;
    }
}

DelayFn resolveDelay(const(char)[] name) {
    switch (name) {
        default: return null;
    }
}

DeliverFn resolveDeliver(const(char)[] name) {
    switch (name) {
        case "upstreamBriefingDeliver": return &control_handlers.upstreamBriefingDeliver;
        default: return null;
    }
}

// Every name the sand may carry is one this engine holds, or the build fails.
static foreach (n; checkNames) static assert(resolveCheck(n) !is null, "no check handler " ~ n);
static foreach (n; delayNames) static assert(resolveDelay(n) !is null, "no delay handler " ~ n);
static foreach (n; deliverNames) static assert(resolveDeliver(n) !is null, "no deliver handler " ~ n);

// A sand that names a handler this engine does not hold, said where it is met.
void unheld(string kind, const(char)[] name, string control) {
    import errors : GroundError, deliverError;
    import zbuf : ZBuf;
    __gshared ZBuf said;
    said.reset();
    said.put("the sand names a ");
    said.put(kind);
    said.put(" handler this ground does not hold: ");
    said.put(name);
    GroundError err;
    err.origin = "handlers.unheld";
    err.message = cast(string) said.slice();
    err.exitCode = -1;
    err.controlName = control;
    cast(void) deliverError(err);
}
