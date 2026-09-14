module ritual.consent;

import ritual.position : RitualState;
import sessionmode : SessionMode, grants;

// What a performance authorises: everything, for as long as it is live, in a
// session whose mode already grants. Manual is the person asking to be asked,
// and no performance lifts that; q-deploy performs in the user's own checkout.
bool performanceAnswers(bool valid, RitualState state, SessionMode mode) {
    return valid && state == RitualState.Live && grants(mode);
}

// The tree is the boundary. A performance has its own worktree and branch, so
// ground answers every tool call inside it and a prompt reaches nobody.
