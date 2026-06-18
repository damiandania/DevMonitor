#import "dm_exc.h"

BOOL dm_try(void (^_Nonnull block)(void)) {
    @try {
        block();
        return YES;
    } @catch (NSException *e) {
        NSLog(@"[DevMonitor] swallowed Objective-C exception: %@ — %@", e.name, e.reason);
        return NO;
    }
}
