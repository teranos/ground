module ritual.consent;

import ritual.position : RitualState;

// What a performance authorises: everything, for as long as it is live.
bool performanceAnswers(bool valid, RitualState state) {
    return valid && state == RitualState.Live;
}

// This was a list of four shell commands until 2026-08-13. `chapter-1786287252`
// sat on a permission prompt for a Write, which no list of commands can name,
// and ended `aborted` — the one ending a person causes.
