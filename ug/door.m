// The browser coming back to mycelia's door.
//
// The node sends the browser to mycelia://door?home=<ticket> once the passkey
// is done at home (QNTX server/auth/homeward.go). macOS hands that url to
// Mycelia.app as an event, which only a running application receives: the
// mycelia launchd keeps never becomes one, so the system starts another,
// which takes the url here and gives it to the one that is running.

#import <AppKit/AppKit.h>
#include <string.h>

@interface MyceliaDoor : NSObject <NSApplicationDelegate>
@property (copy) NSString *url;
@end

static void stopNow(NSApplication *app) {
    [app stop:nil];
    // stop: is seen after the next event, so one is sent.
    NSEvent *e = [NSEvent otherEventWithType:NSEventTypeApplicationDefined location:NSZeroPoint
                               modifierFlags:0 timestamp:0 windowNumber:0 context:nil
                                     subtype:0 data1:0 data2:0];
    [app postEvent:e atStart:YES];
}

@implementation MyceliaDoor
- (void)application:(NSApplication *)app openURLs:(NSArray<NSURL *> *)urls {
    self.url = urls.firstObject.absoluteString;
    stopNow(app);
}
@end

// The url the system opened Mycelia.app with, into out, waiting up to
// seconds for it. Its length; 0 when none came.
int door_url(char *out, int cap, double seconds) {
    @autoreleasepool {
        NSApplication *app = [NSApplication sharedApplication];
        // No Dock icon and no menu: nothing is shown for a door.
        [app setActivationPolicy:NSApplicationActivationPolicyProhibited];
        MyceliaDoor *door = [MyceliaDoor new];
        app.delegate = door;
        [NSTimer scheduledTimerWithTimeInterval:seconds repeats:NO block:^(NSTimer *t) {
            (void) t;
            stopNow(app);
        }];
        [app run];
        if (door.url == nil) return 0;
        const char *s = door.url.UTF8String;
        size_t n = strlen(s);
        if ((int) n >= cap) return 0;
        memcpy(out, s, n);
        out[n] = 0;
        return (int) n;
    }
}
