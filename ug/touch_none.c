// 「[Opus 5.5] The Keychain and the door, on a machine that has neither (ug/touch.c and」
// 「[Opus 5.5] ug/door.m are the Mac's).」
//
// 「[Opus 5.5] mycelia on such a machine asks the node and keeps what it learns for the」
// 「[Opus 5.5] sessions there, as on the Mac. It holds no person's session, so a press made」
// 「[Opus 5.5] on it is answered with why, and the press is the Mac's to make.」

#include <string.h>

// 「[Opus 5.5] Apple's errSecUnimplemented, which is what this is: no Keychain here.」
#define NO_KEYCHAIN (-4)

int touch_keep(const unsigned char *held, int n) {
    (void) held;
    (void) n;
    return NO_KEYCHAIN;
}

int touch_take(unsigned char *out, int cap, const char *prompt, int *n) {
    (void) out;
    (void) cap;
    (void) prompt;
    *n = 0;
    return NO_KEYCHAIN;
}

// 「[Opus 5.5] There was never a seed kept here: nothing to remove, said as nothing found.」
int touch_forget_seed(void) {
    return -25300;
}

void touch_said(int st, char *out, int cap) {
    const char *said = st == NO_KEYCHAIN
        ? "this machine keeps no Keychain, so mycelia here holds no person's session: presses are made on the Mac, in Mycelia.app"
        : "";
    out[0] = 0;
    if (cap <= 0) return;
    strncpy(out, said, (size_t) cap - 1);
    out[cap - 1] = 0;
}

// 「[Opus 5.5] No browser comes back to a door here.」
int door_url(char *out, int cap, double seconds) {
    (void) seconds;
    if (cap > 0) out[0] = 0;
    return 0;
}
