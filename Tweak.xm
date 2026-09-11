#import <Foundation/Foundation.h>
#import <objc/message.h>
#import <notify.h>

static NSString * const WSSMFWhatsAppBundle = @"net.whatsapp.WhatsApp";
static NSString * const WSSMFWhatsAppBusinessBundle = @"net.whatsapp.WhatsAppSMB";
static NSString * const WSSMFScheduleIDKey = @"WatusiMessageScheduleID";
static NSString * const WSSMFSchedulesPath = @"/var/mobile/Library/Preferences/com.fouadraheb.watusi.scheduled-messages.plist";
static NSString * const WSSMFRunningSchedulePath = @"/var/mobile/Library/Preferences/com.fouadraheb.running-schedule-info.plist";
static NSString * const WSSMFDebugPath = @"/var/mobile/Library/Preferences/com.551.watusischeduledmsgfix-debug.plist";
static NSString * const WSSMFFiredPath = @"/var/mobile/Library/Preferences/com.551.watusischeduledmsgfix-fired.plist";
static const char *WSSMFPushNotificationName = "com.fouadraheb.watusi.pushkit-notification";

static NSArray *WSSMFCachedSchedules = nil;
static NSMutableDictionary *WSSMFFired = nil;
static dispatch_source_t WSSMFTimer = nil;
static NSUInteger WSSMFTick = 0;

static BOOL WSSMFIsWhatsAppBundle(NSString *bundleID) {
    if (![bundleID isKindOfClass:[NSString class]]) return NO;
    return [bundleID isEqualToString:WSSMFWhatsAppBundle] ||
           [bundleID isEqualToString:WSSMFWhatsAppBusinessBundle];
}

static NSString *WSSMFBundleIdentifier(id object) {
    if ([object isKindOfClass:[NSString class]]) {
        return WSSMFIsWhatsAppBundle(object) ? object : nil;
    }

    NSArray *selectorNames = @[@"bundleIdentifier", @"bundleID", @"applicationBundleIdentifier", @"identifier"];
    for (NSString *selectorName in selectorNames) {
        SEL selector = NSSelectorFromString(selectorName);
        @try {
            if ([object respondsToSelector:selector]) {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
                id value = [object performSelector:selector];
#pragma clang diagnostic pop
                if ([value isKindOfClass:[NSString class]] && WSSMFIsWhatsAppBundle(value)) {
                    return value;
                }
            }
        } @catch (__unused NSException *exception) {}
    }

    return nil;
}

static void WSSMFWriteDebug(NSDictionary *extra) {
    NSMutableDictionary *debug = [NSMutableDictionary dictionary];
    debug[@"version"] = @"1.0.2";
    debug[@"date"] = [NSDate date];
    if (extra) [debug addEntriesFromDictionary:extra];
    [debug writeToFile:WSSMFDebugPath atomically:YES];
}

static NSDate *WSSMFDateFromValue(id value) {
    if ([value isKindOfClass:[NSDate class]]) return value;
    if ([value isKindOfClass:[NSNumber class]]) {
        return [NSDate dateWithTimeIntervalSince1970:[value doubleValue]];
    }
    if ([value isKindOfClass:[NSString class]]) {
        static NSDateFormatter *formatter = nil;
        static dispatch_once_t onceToken;
        dispatch_once(&onceToken, ^{
            formatter = [[NSDateFormatter alloc] init];
            formatter.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
            formatter.timeZone = [NSTimeZone localTimeZone];
            formatter.dateFormat = @"yyyy-MM-dd HH:mm:ss Z";
        });
        return [formatter dateFromString:value];
    }
    return nil;
}

static NSString *WSSMFKeyForSchedule(id scheduleID, NSDate *date) {
    if (!scheduleID || !date) return nil;
    long long milliseconds = (long long)llround([date timeIntervalSince1970] * 1000.0);
    return [NSString stringWithFormat:@"%@|%lld", [scheduleID description], milliseconds];
}

static void WSSMFLoadFiredState(void) {
    NSDictionary *stored = [NSDictionary dictionaryWithContentsOfFile:WSSMFFiredPath];
    WSSMFFired = stored ? [stored mutableCopy] : [NSMutableDictionary dictionary];

    NSDate *now = [NSDate date];
    for (NSString *key in [WSSMFFired.allKeys copy]) {
        NSDate *date = WSSMFFired[key];
        if (![date isKindOfClass:[NSDate class]] || [now timeIntervalSinceDate:date] > 604800.0) {
            [WSSMFFired removeObjectForKey:key];
        }
    }
}

static void WSSMFMarkFired(NSString *key) {
    if (!key.length) return;
    if (!WSSMFFired) WSSMFLoadFiredState();
    WSSMFFired[key] = [NSDate date];
    [WSSMFFired writeToFile:WSSMFFiredPath atomically:YES];
}

static BOOL WSSMFAlreadyFired(NSString *key) {
    if (!key.length) return YES;
    if (!WSSMFFired) WSSMFLoadFiredState();
    return WSSMFFired[key] != nil;
}

static void WSSMFReloadSchedules(void) {
    NSDictionary *root = [NSDictionary dictionaryWithContentsOfFile:WSSMFSchedulesPath];
    id schedules = [root isKindOfClass:[NSDictionary class]] ? root[@"schedules"] : nil;

    if ([schedules isKindOfClass:[NSArray class]]) {
        WSSMFCachedSchedules = [schedules copy];
    } else {
        WSSMFCachedSchedules = @[];
    }
}

static BOOL WSSMFManualBridge(id scheduleID, NSString *bundleID) {
    if (!scheduleID || !WSSMFIsWhatsAppBundle(bundleID)) return NO;

    NSDictionary *runningSchedule = @{
        @"userInfo": @{ WSSMFScheduleIDKey: scheduleID },
        @"bundleID": bundleID
    };

    if (![runningSchedule writeToFile:WSSMFRunningSchedulePath atomically:YES]) {
        return NO;
    }

    return notify_post(WSSMFPushNotificationName) == NOTIFY_STATUS_OK;
}

static NSString *WSSMFFireSchedule(id scheduleID, NSString *bundleID) {
    Class helperClass = NSClassFromString(@"WSSchedulerHelper");
    SEL selector = NSSelectorFromString(@"sendPushNotificationForScheduleID:bundleIdentifier:");

    if (helperClass && [helperClass respondsToSelector:selector]) {
        @try {
            ((void (*)(id, SEL, id, id))objc_msgSend)(helperClass, selector, scheduleID, bundleID);
            return @"called-watusi-helper";
        } @catch (__unused NSException *exception) {
            // Fall through to the exact file + Darwin-notification path used by WatusiSB.
        }
    }

    return WSSMFManualBridge(scheduleID, bundleID) ? @"manual-bridge-posted" : @"bridge-failed";
}

static void WSSMFCheckSchedules(void) {
    WSSMFTick++;
    if (!WSSMFCachedSchedules || (WSSMFTick % 5) == 0) {
        WSSMFReloadSchedules();
    }

    NSDate *now = [NSDate date];
    for (id item in WSSMFCachedSchedules) {
        if (![item isKindOfClass:[NSDictionary class]]) continue;

        NSDictionary *schedule = (NSDictionary *)item;
        id scheduleID = schedule[@"id"] ?: schedule[@"uniqueID"];
        NSDate *scheduledDate = WSSMFDateFromValue(schedule[@"date"]);
        if (!scheduleID || !scheduledDate) continue;

        NSTimeInterval lateness = [now timeIntervalSinceDate:scheduledDate];
        // Fire only at the actual due time. Ignore old inactive schedules so installing
        // this tweak never suddenly sends historical messages.
        if (lateness < 0.0 || lateness > 30.0) continue;

        NSString *key = WSSMFKeyForSchedule(scheduleID, scheduledDate);
        if (WSSMFAlreadyFired(key)) continue;

        // This build targets the regular WhatsApp package used on the reported setup.
        // The Watusi helper receives the same bundle identifier its SpringBoard hook used.
        NSString *bundleID = WSSMFWhatsAppBundle;
        NSString *result = WSSMFFireSchedule(scheduleID, bundleID);
        WSSMFMarkFired(key);

        WSSMFWriteDebug(@{
            @"result": result ?: @"unknown",
            @"source": @"direct-schedule-store",
            @"scheduleID": [scheduleID description] ?: @"unknown",
            @"scheduledDate": scheduledDate,
            @"latenessSeconds": @(lateness),
            @"bundleID": bundleID,
            @"scheduleCount": @(WSSMFCachedSchedules.count),
            @"helperClassFound": @(NSClassFromString(@"WSSchedulerHelper") != Nil)
        });
    }
}

static void WSSMFStartSpringBoardScheduler(void) {
    WSSMFLoadFiredState();
    WSSMFReloadSchedules();

    Class helperClass = NSClassFromString(@"WSSchedulerHelper");
    SEL selector = NSSelectorFromString(@"sendPushNotificationForScheduleID:bundleIdentifier:");
    WSSMFWriteDebug(@{
        @"result": @"scheduler-started",
        @"source": @"direct-schedule-store",
        @"scheduleStoreExists": @([[NSFileManager defaultManager] fileExistsAtPath:WSSMFSchedulesPath]),
        @"scheduleCount": @(WSSMFCachedSchedules.count),
        @"helperClassFound": @(helperClass != Nil),
        @"helperMethodFound": @(helperClass && [helperClass respondsToSelector:selector])
    });

    WSSMFTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_main_queue());
    if (!WSSMFTimer) return;

    dispatch_source_set_timer(WSSMFTimer,
                              dispatch_time(DISPATCH_TIME_NOW, 1 * NSEC_PER_SEC),
                              1 * NSEC_PER_SEC,
                              100 * NSEC_PER_MSEC);
    dispatch_source_set_event_handler(WSSMFTimer, ^{
        WSSMFCheckSchedules();
    });
    dispatch_resume(WSSMFTimer);
}

// Keep the callservicesd launch safeguard from v1.0.0. Once Watusi's helper
// posts its fake VoIP push, iOS must be allowed to wake WhatsApp.
%hook CSDVoIPApplicationController

- (BOOL)_isApplicationPreventedFromBeingLaunched:(id)application {
    NSString *bundleID = WSSMFBundleIdentifier(application);
    if (WSSMFIsWhatsAppBundle(bundleID)) {
        return NO;
    }
    return %orig;
}

%end

%ctor {
    @autoreleasepool {
        NSString *bundleID = [[NSBundle mainBundle] bundleIdentifier];
        NSString *processName = [[NSProcessInfo processInfo] processName];
        if ([bundleID isEqualToString:@"com.apple.springboard"] || [processName isEqualToString:@"SpringBoard"]) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
                WSSMFStartSpringBoardScheduler();
            });
        }
    }
}
