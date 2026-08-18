module ritual.consent;

import ritual.position : RitualState;

// What a performance authorises: everything, for as long as it is live.
bool performanceAnswers(bool valid, RitualState state) {
    return valid && state == RitualState.Live;
}

// The tree is the boundary. A performance has its own worktree and branch, so
// ground answers every tool call inside it and a prompt reaches nobody.
