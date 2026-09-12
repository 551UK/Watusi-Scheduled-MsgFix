#import <Foundation/Foundation.h>

static NSString * const WSSMFWAVersion = @"1.0.12";
static const NSTimeInterval WSSMFDedupeWindow = 60.0;

static NSMutableDictionary<NSString *, NSDate *> *gRecentScheduleIDs;
static NSObject *gDedupeLock;
static BOOL gDedupeHookInstalled = NO;

static void WSSMFEnsureDedupeState(void) {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        gRecentScheduleIDs = [NSMutableDictionary dictionary];
        gDedupeLock = [NSObject new];
    });
}

static NSString *WSSMFDedupeDebugPath(void) {
    return [NSHomeDirectory() stringByAppendingPathComponent:@"Library/Caches/com.551.watusischeduledmsgfix-wa-dedupe.plist"];
}

static void WSSMFWriteDedupeDebug(NSString *route, id scheduleID, NSString *result) {
    NSMutableDictionary *debug = [NSMutableDictionary dictionary];
    debug[@"version"] = WSSMFWAVersion;
    debug[@"date"] = [NSDate date];
    debug[@"process"] = [[NSProcessInfo processInfo] processName] ?: @"unknown";
    debug[@"route"] = route ?: @"unknown";
    debug[@"scheduleID"] = scheduleID ? [scheduleID description] : @"nil";
    debug[@"result"] = result ?: @"unknown";
    [debug writeToFile:WSSMFDedupeDebugPath() atomically:YES];
}

static BOOL WSSMFClaimScheduleID(id scheduleID, NSString *route) {
    if (!scheduleID) return YES;
    WSSMFEnsureDedupeState();

    NSString *key = [scheduleID description];
    if (!key.length) return YES;

    NSDate *now = [NSDate date];
    BOOL allow = YES;

    @synchronized (gDedupeLock) {
        for (NSString *existingKey in [gRecentScheduleIDs.allKeys copy]) {
            NSDate *date = gRecentScheduleIDs[existingKey];
            if (!date || [now timeIntervalSinceDate:date] > WSSMFDedupeWindow) {
                [gRecentScheduleIDs removeObjectForKey:existingKey];
            }
        }

        NSDate *previous = gRecentScheduleIDs[key];
        if (previous && [now timeIntervalSinceDate:previous] <= WSSMFDedupeWindow) {
            allow = NO;
        } else {
            gRecentScheduleIDs[key] = now;
        }
    }

    WSSMFWriteDedupeDebug(route, scheduleID, allow ? @"allowed-first-route" : @"suppressed-duplicate-route");
    return allow;
}

%group WSSMFDedupe

%hook WSScheduleHandler

- (void)processScheduleFromPushKitNotificationWithID:(id)scheduleID {
    if (!WSSMFClaimScheduleID(scheduleID, @"pushkit")) return;
    %orig;
}

- (void)processScheduleFromLocalNotificationWhileAppActiveWithID:(id)scheduleID {
    if (!WSSMFClaimScheduleID(scheduleID, @"local-active")) return;
    %orig;
}

%end

%end

static void WSSMFTryInstallDedupeHook(void) {
    if (gDedupeHookInstalled) return;

    if (NSClassFromString(@"WSScheduleHandler")) {
        %init(WSSMFDedupe);
        gDedupeHookInstalled = YES;
        WSSMFWriteDedupeDebug(@"hook", @"none", @"installed");
        return;
    }

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 500 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{
        WSSMFTryInstallDedupeHook();
    });
}

%ctor {
    @autoreleasepool {
        NSString *bundleID = [[NSBundle mainBundle] bundleIdentifier];
        if ([bundleID isEqualToString:@"net.whatsapp.WhatsApp"] ||
            [bundleID isEqualToString:@"net.whatsapp.WhatsAppSMB"]) {
            WSSMFEnsureDedupeState();
            dispatch_async(dispatch_get_main_queue(), ^{
                WSSMFTryInstallDedupeHook();
            });
        }
    }
}
