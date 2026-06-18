#ifndef DM_EXC_H
#define DM_EXC_H

#import <Foundation/Foundation.h>

/// Runs `block`, swallowing any Objective-C `NSException` it raises (returns NO if one was caught,
/// YES otherwise). Lets Swift guard calls into frameworks that abort the process via NSException —
/// which Swift cannot `try`/`catch` — e.g. `UNUserNotificationCenter.current()` on a bundle the
/// notification daemon rejects. A supervisor must never die because of a non-essential side effect.
BOOL dm_try(void (^_Nonnull block)(void));

#endif
