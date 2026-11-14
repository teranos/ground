// The person's session at the node, kept in the Keychain behind Touch ID.
//
// "kept. kept bro, i want to put my finger on, and then not have to thing about it anymore"
//
// Only a binary signed with the team's profile and its Keychain group sees the
// item (an unsigned one is refused -34018, and finds nothing), and taking the
// session out asks for a touch. What mycelia takes out it holds until it stops.

#include <Security/Security.h>
#include <string.h>

static CFMutableDictionaryRef session(void) {
    CFMutableDictionaryRef q = CFDictionaryCreateMutable(NULL, 0, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    CFDictionarySetValue(q, kSecClass, kSecClassGenericPassword);
    CFDictionarySetValue(q, kSecAttrService, CFSTR("mycelia"));
    CFDictionarySetValue(q, kSecAttrAccount, CFSTR("session"));
    CFDictionarySetValue(q, kSecUseDataProtectionKeychain, kCFBooleanTrue);
    return q;
}

// Keeps the session, readable only with a touch on this device, in place of
// the one kept before: a new passkey at home is a new session. The OSStatus.
int touch_keep(const unsigned char *held, int n) {
    CFMutableDictionaryRef gone = session();
    OSStatus st = SecItemDelete(gone);
    CFRelease(gone);
    if (st != errSecSuccess && st != errSecItemNotFound) return st;

    CFErrorRef err = NULL;
    SecAccessControlRef ac = SecAccessControlCreateWithFlags(NULL,
        kSecAttrAccessibleWhenPasscodeSetThisDeviceOnly, kSecAccessControlUserPresence, &err);
    if (!ac) return errSecParam;
    CFMutableDictionaryRef q = session();
    CFDictionarySetValue(q, kSecAttrAccessControl, ac);
    CFDataRef v = CFDataCreate(NULL, held, n);
    CFDictionarySetValue(q, kSecValueData, v);
    st = SecItemAdd(q, NULL);
    CFRelease(v);
    CFRelease(q);
    CFRelease(ac);
    return st;
}

// Takes the session out into out, asking for a touch with prompt. The
// OSStatus; the bytes taken in *n.
int touch_take(unsigned char *out, int cap, const char *prompt, int *n) {
    *n = 0;
    CFMutableDictionaryRef q = session();
    CFDictionarySetValue(q, kSecReturnData, kCFBooleanTrue);
    CFStringRef p = CFStringCreateWithCString(NULL, prompt, kCFStringEncodingUTF8);
    CFDictionarySetValue(q, kSecUseOperationPrompt, p);
    CFTypeRef got = NULL;
    OSStatus st = SecItemCopyMatching(q, &got);
    if (st == errSecSuccess) {
        CFIndex len = CFDataGetLength((CFDataRef) got);
        if (len > cap) st = errSecBufferTooSmall;
        else { memcpy(out, CFDataGetBytePtr((CFDataRef) got), len); *n = (int) len; }
        CFRelease(got);
    }
    CFRelease(p);
    CFRelease(q);
    return st;
}

// What an OSStatus says, in Apple's words, into out.
void touch_said(int st, char *out, int cap) {
    out[0] = 0;
    CFStringRef m = SecCopyErrorMessageString(st, NULL);
    if (m) { CFStringGetCString(m, out, cap, kCFStringEncodingUTF8); CFRelease(m); }
}
