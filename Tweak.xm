#import <Foundation/Foundation.h>
#import <objc/message.h>
#import <notify.h>
#import <unistd.h>

static NSString * const WSSMFVersion = @"1.0.5";
static NSString * const WSSMFWhatsAppBundle = @"net.whatsapp.WhatsApp";
static NSString * const WSSMFWhatsAppBusinessBundle = @"net.whatsapp.WhatsAppSMB";
static NSString * const WSSMFScheduleIDKey = @"WatusiMessageScheduleID";
static NSString * const WSSMFScheduleRelativePath = @"Library/Preferences/com.fouadraheb.watusi.scheduled-messages.plist";
static NSString * const WSSMFContainersRoot = @"/var/mobile/Containers/Data/Application";
static NSString * const WSSMFRunningSchedulePath = @"/var/mobile/Library/Preferences/com.fouadraheb.running-schedule-info.plist";
static NSString * const WSSMFDebugPath = @"/var/mobile/Library/Preferences/com.551.watusischeduledmsgfix-debug.plist";
static NSString * const WSSMFFiredPath = @"/var/mobile/Library/Preferences/com.551.watusischeduledmsgfix-fired.plist";
static const char *WSSMFPushNotificationName = "com.fouadraheb.watusi.pushkit-notification";

static dispatch_queue_t gSchedulerQueue;
static dispatch_source_t gSchedulerTimer;
static NSMutableDictionary<NSString *, NSDate *> *gFired;
static NSUInteger gTick = 0;

static BOOL WSSMFIsWhatsAppBundle(NSString *bundleID) {
    return [bundleID isKindOfClass:[NSString class]] &&
           ([bundleID isEqualToString:WSSMFWhatsAppBundle] ||
            [bundleID isEqualToString:WSSMFWhatsAppBusinessBundle]);
}

static id WSSMFSafeValue(id object, NSString *name) {
    if (!object || !name.length || object == [NSNull null]) return nil;
    SEL selector = NSSelectorFromString(name);
    @try {
        if ([object respondsToSelector:selector]) {
            return ((id (*)(id, SEL))objc_msgSend)(object, selector);
        }
        return [object valueForKey:name];
    } @catch (__unused NSException *exception) {
        return nil;
    }
}

static NSString *WSSMFBundleIdentifier(id object) {
    if ([object isKindOfClass:[NSString class]] && WSSMFIsWhatsAppBundle(object)) return object;
    for (NSString *name in @[@"bundleIdentifier", @"bundleID", @"applicationBundleIdentifier", @"identifier"]) {
        id value = WSSMFSafeValue(object, name);
        if ([value isKindOfClass:[NSString class]] && WSSMFIsWhatsAppBundle(value)) return value;
    }
    return nil;
}

static void WSSMFWriteDebug(NSDictionary *extra) {
    NSMutableDictionary *debug = [NSMutableDictionary dictionary];
    debug[@"version"] = WSSMFVersion;
    debug[@"date"] = [NSDate date];
    debug[@"pid"] = @((int)getpid());
    debug[@"process"] = [[NSProcessInfo processInfo] processName] ?: @"unknown";
    if (extra) [debug addEntriesFromDictionary:extra];
    [debug writeToFile:WSSMFDebugPath atomically:YES];
}

static NSDate *WSSMFDateFromValue(id value) {
    if ([value isKindOfClass:[NSDate class]]) return value;
    if ([value isKindOfClass:[NSNumber class]]) {
        NSTimeInterval n = [value doubleValue];
        // Accept milliseconds as well as seconds.
        if (n > 100000000000.0) n /= 1000.0;
        return [NSDate dateWithTimeIntervalSince1970:n];
    }
    if ([value isKindOfClass:[NSString class]]) {
        NSString *string = (NSString *)value;
        NSArray<NSString *> *formats = @[@"yyyy-MM-dd HH:mm:ss Z", @"yyyy-MM-dd'T'HH:mm:ssZZZZZ", @"yyyy-MM-dd'T'HH:mm:ss.SSSZZZZZ"];
        for (NSString *format in formats) {
            NSDateFormatter *formatter = [[NSDateFormatter alloc] init];
            formatter.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
            formatter.timeZone = [NSTimeZone localTimeZone];
            formatter.dateFormat = format;
            NSDate *date = [formatter dateFromString:string];
            if (date) return date;
        }
    }
    return nil;
}

static void WSSMFLoadFired(void) {
    NSDictionary *stored = [NSDictionary dictionaryWithContentsOfFile:WSSMFFiredPath];
    gFired = stored ? [stored mutableCopy] : [NSMutableDictionary dictionary];
    NSDate *now = [NSDate date];
    for (NSString *key in [gFired.allKeys copy]) {
        NSDate *date = gFired[key];
        if (![date isKindOfClass:[NSDate class]] || [now timeIntervalSinceDate:date] > 1209600.0) {
            [gFired removeObjectForKey:key];
        }
    }
    [gFired writeToFile:WSSMFFiredPath atomically:YES];
}

static NSString *WSSMFFiredKey(NSString *bundleID, id scheduleID, NSDate *date) {
    if (!bundleID.length || !scheduleID || !date) return nil;
    long long ms = (long long)llround([date timeIntervalSince1970] * 1000.0);
    return [NSString stringWithFormat:@"%@|%@|%lld", bundleID, [scheduleID description], ms];
}

static BOOL WSSMFAlreadyFired(NSString *key) {
    if (!key.length) return YES;
    if (!gFired) WSSMFLoadFired();
    return gFired[key] != nil;
}

static void WSSMFMarkFired(NSString *key) {
    if (!key.length) return;
    if (!gFired) WSSMFLoadFired();
    gFired[key] = [NSDate date];
    [gFired writeToFile:WSSMFFiredPath atomically:YES];
}

static NSArray<NSDictionary *> *WSSMFScheduleStores(void) {
    NSFileManager *fm = [NSFileManager defaultManager];
    NSError *error = nil;
    NSArray<NSString *> *entries = [fm contentsOfDirectoryAtPath:WSSMFContainersRoot error:&error];
    NSMutableArray<NSDictionary *> *stores = [NSMutableArray array];

    for (NSString *entry in entries ?: @[]) {
        NSString *container = [WSSMFContainersRoot stringByAppendingPathComponent:entry];
        NSString *metadataPath = [container stringByAppendingPathComponent:@".com.apple.mobile_container_manager.metadata.plist"];
        NSDictionary *metadata = [NSDictionary dictionaryWithContentsOfFile:metadataPath];
        NSString *bundleID = [metadata[@"MCMMetadataIdentifier"] isKindOfClass:[NSString class]] ? metadata[@"MCMMetadataIdentifier"] : nil;
        if (!WSSMFIsWhatsAppBundle(bundleID)) continue;

        NSString *schedulePath = [container stringByAppendingPathComponent:WSSMFScheduleRelativePath];
        [stores addObject:@{
            @"bundleID": bundleID,
            @"container": container,
            @"schedulePath": schedulePath,
            @"exists": @([fm fileExistsAtPath:schedulePath])
        }];
    }

    // Fallback: if metadata lookup changes, locate the exact Watusi schedule file.
    if (stores.count == 0) {
        for (NSString *entry in entries ?: @[]) {
            NSString *container = [WSSMFContainersRoot stringByAppendingPathComponent:entry];
            NSString *schedulePath = [container stringByAppendingPathComponent:WSSMFScheduleRelativePath];
            if ([fm fileExistsAtPath:schedulePath]) {
                [stores addObject:@{
                    @"bundleID": WSSMFWhatsAppBundle,
                    @"container": container,
                    @"schedulePath": schedulePath,
                    @"exists": @YES
                }];
            }
        }
    }

    return stores;
}

static NSArray *WSSMFReadSchedules(NSString *path, NSString **rootTypeOut) {
    id root = [NSDictionary dictionaryWithContentsOfFile:path];
    if (!root) root = [NSArray arrayWithContentsOfFile:path];

    if ([root isKindOfClass:[NSArray class]]) {
        if (rootTypeOut) *rootTypeOut = @"array";
        return root;
    }

    if ([root isKindOfClass:[NSDictionary class]]) {
        NSDictionary *dict = (NSDictionary *)root;
        for (NSString *key in @[@"schedules", @"scheduledMessages", @"messages", @"items"]) {
            id value = dict[key];
            if ([value isKindOfClass:[NSArray class]]) {
                if (rootTypeOut) *rootTypeOut = [NSString stringWithFormat:@"dictionary:%@", key];
                return value;
            }
        }
        if (rootTypeOut) *rootTypeOut = @"dictionary:no-array-key";
    } else if (rootTypeOut) {
        *rootTypeOut = root ? NSStringFromClass([root class]) : @"unreadable";
    }

    return @[];
}

static BOOL WSSMFManualBridge(id scheduleID, NSString *bundleID, NSString **resultOut) {
    NSDictionary *runningSchedule = @{
        @"userInfo": @{ WSSMFScheduleIDKey: scheduleID },
        @"bundleID": bundleID
    };

    if (![runningSchedule writeToFile:WSSMFRunningSchedulePath atomically:YES]) {
        if (resultOut) *resultOut = @"manual-bridge-write-failed";
        return NO;
    }

    uint32_t status = notify_post(WSSMFPushNotificationName);
    if (status != NOTIFY_STATUS_OK) {
        if (resultOut) *resultOut = [NSString stringWithFormat:@"manual-notify-failed-%u", status];
        return NO;
    }

    if (resultOut) *resultOut = @"manual-watusi-pushkit-bridge-posted";
    return YES;
}

static BOOL WSSMFFire(id scheduleID, NSString *bundleID, NSString **resultOut) {
    if (!scheduleID || !WSSMFIsWhatsAppBundle(bundleID)) {
        if (resultOut) *resultOut = @"invalid-schedule-or-bundle";
        return NO;
    }

    Class helper = NSClassFromString(@"WSSchedulerHelper");
    SEL selector = NSSelectorFromString(@"sendPushNotificationForScheduleID:bundleIdentifier:");
    if (helper && [helper respondsToSelector:selector]) {
        @try {
            ((void (*)(id, SEL, id, id))objc_msgSend)(helper, selector, scheduleID, bundleID);
            if (resultOut) *resultOut = @"called-watusi-sendPush-helper";
            return YES;
        } @catch (__unused NSException *exception) {
            // Fall back to Watusi's exact file + Darwin notification bridge.
        }
    }

    return WSSMFManualBridge(scheduleID, bundleID, resultOut);
}

static void WSSMFScanSchedules(NSString *reason) {
    NSDate *now = [NSDate date];
    NSArray<NSDictionary *> *stores = WSSMFScheduleStores();
    NSUInteger scheduleCount = 0;
    NSMutableArray<NSString *> *storePaths = [NSMutableArray array];
    NSMutableArray<NSString *> *rootTypes = [NSMutableArray array];
    NSDate *nextDue = nil;
    NSMutableDictionary *lastEvent = [NSMutableDictionary dictionary];

    for (NSDictionary *store in stores) {
        NSString *bundleID = store[@"bundleID"];
        NSString *path = store[@"schedulePath"];
        if (path.length) [storePaths addObject:path];

        NSString *rootType = nil;
        NSArray *schedules = WSSMFReadSchedules(path, &rootType);
        [rootTypes addObject:rootType ?: @"unknown"];
        scheduleCount += schedules.count;

        for (id object in schedules) {
            if (![object isKindOfClass:[NSDictionary class]]) continue;
            NSDictionary *schedule = (NSDictionary *)object;
            id scheduleID = schedule[@"id"] ?: schedule[@"uniqueID"];
            NSDate *scheduledDate = WSSMFDateFromValue(schedule[@"date"]);
            if (!scheduleID || !scheduledDate) continue;

            NSTimeInterval lateness = [now timeIntervalSinceDate:scheduledDate];
            if (lateness < 0.0) {
                if (!nextDue || [scheduledDate compare:nextDue] == NSOrderedAscending) nextDue = scheduledDate;
                continue;
            }

            // Do not send historical entries. Three minutes allows for timer/lock wake jitter.
            if (lateness > 180.0) continue;

            NSString *key = WSSMFFiredKey(bundleID, scheduleID, scheduledDate);
            if (WSSMFAlreadyFired(key)) continue;

            NSString *result = nil;
            BOOL fired = WSSMFFire(scheduleID, bundleID, &result);
            if (fired) WSSMFMarkFired(key);

            lastEvent[@"lastResult"] = result ?: @"unknown";
            lastEvent[@"lastScheduleID"] = [scheduleID description] ?: @"unknown";
            lastEvent[@"lastBundleID"] = bundleID ?: @"unknown";
            lastEvent[@"lastScheduledDate"] = scheduledDate;
            lastEvent[@"lastLatenessSeconds"] = @(lateness);
            lastEvent[@"lastMarkedFired"] = @(fired);
        }
    }

    gTick++;
    if ((gTick % 10) == 0 || lastEvent.count > 0 || [reason isEqualToString:@"scheduler-start"]) {
        NSMutableDictionary *debug = [NSMutableDictionary dictionaryWithDictionary:@{
            @"event": reason ?: @"scan",
            @"result": @"springboard-direct-store-scan",
            @"storeCount": @(stores.count),
            @"scheduleCount": @(scheduleCount),
            @"storePaths": storePaths,
            @"rootTypes": rootTypes,
            @"nextDue": nextDue ?: @"none",
            @"helperFound": @(NSClassFromString(@"WSSchedulerHelper") != Nil),
            @"helperMethodFound": @(NSClassFromString(@"WSSchedulerHelper") && [NSClassFromString(@"WSSchedulerHelper") respondsToSelector:NSSelectorFromString(@"sendPushNotificationForScheduleID:bundleIdentifier:")])
        }];
        [debug addEntriesFromDictionary:lastEvent];
        WSSMFWriteDebug(debug);
    }
}

static void WSSMFStartSpringBoardScheduler(void) {
    WSSMFLoadFired();
    gSchedulerQueue = dispatch_queue_create("com.551.watusischeduledmsgfix.springboard", DISPATCH_QUEUE_SERIAL);
    gSchedulerTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, gSchedulerQueue);
    dispatch_source_set_timer(gSchedulerTimer,
                              dispatch_time(DISPATCH_TIME_NOW, 1 * NSEC_PER_SEC),
                              1 * NSEC_PER_SEC,
                              100 * NSEC_PER_MSEC);
    dispatch_source_set_event_handler(gSchedulerTimer, ^{
        WSSMFScanSchedules(@"timer-scan");
    });
    dispatch_resume(gSchedulerTimer);
    dispatch_async(gSchedulerQueue, ^{ WSSMFScanSchedules(@"scheduler-start"); });
}

// Keep the wake safeguard in callservicesd. This is secondary to the direct
// schedule-store trigger, but prevents iOS from refusing the WhatsApp wake.
%hook CSDVoIPApplicationController

- (BOOL)_isApplicationPreventedFromBeingLaunched:(id)application {
    NSString *bundleID = WSSMFBundleIdentifier(application);
    if (WSSMFIsWhatsAppBundle(bundleID)) return NO;
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
