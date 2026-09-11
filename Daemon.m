#import <Foundation/Foundation.h>
#import <notify.h>
#import <unistd.h>

static NSString * const WSSMFVersion = @"1.0.3";
static NSString * const WSSMFWhatsAppBundle = @"net.whatsapp.WhatsApp";
static NSString * const WSSMFWhatsAppBusinessBundle = @"net.whatsapp.WhatsAppSMB";
static NSString * const WSSMFScheduleIDKey = @"WatusiMessageScheduleID";
static NSString * const WSSMFScheduleRelativePath = @"Library/Preferences/com.fouadraheb.watusi.scheduled-messages.plist";
static NSString * const WSSMFRunningSchedulePath = @"/var/mobile/Library/Preferences/com.fouadraheb.running-schedule-info.plist";
static NSString * const WSSMFDebugPath = @"/var/mobile/Library/Preferences/com.551.watusischeduledmsgfix-debug.plist";
static NSString * const WSSMFFiredPath = @"/var/mobile/Library/Preferences/com.551.watusischeduledmsgfix-fired.plist";
static NSString * const WSSMFContainersRoot = @"/var/mobile/Containers/Data/Application";
static const char *WSSMFPushNotificationName = "com.fouadraheb.watusi.pushkit-notification";
static const char *WSSMFSchedulesChangedName = "com.fouadraheb.watusi.schedules-changed";

static const NSTimeInterval WSSMFGraceSeconds = 120.0;
static const NSTimeInterval WSSMFMaintenanceSeconds = 60.0;

static dispatch_queue_t gQueue;
static dispatch_source_t gDueTimer;
static dispatch_source_t gMaintenanceTimer;
static NSMutableDictionary<NSString *, NSDate *> *gFired;
static int gScheduleChangedToken = 0;

static BOOL WSSMFIsWhatsAppBundle(NSString *bundleID) {
    return [bundleID isEqualToString:WSSMFWhatsAppBundle] ||
           [bundleID isEqualToString:WSSMFWhatsAppBusinessBundle];
}

static void WSSMFWriteDebug(NSDictionary *extra) {
    NSMutableDictionary *debug = [NSMutableDictionary dictionary];
    debug[@"version"] = WSSMFVersion;
    debug[@"date"] = [NSDate date];
    debug[@"pid"] = @((int)getpid());
    if (extra) [debug addEntriesFromDictionary:extra];
    [debug writeToFile:WSSMFDebugPath atomically:YES];
}

static void WSSMFLoadFired(void) {
    NSDictionary *stored = [NSDictionary dictionaryWithContentsOfFile:WSSMFFiredPath];
    gFired = stored ? [stored mutableCopy] : [NSMutableDictionary dictionary];

    NSDate *now = [NSDate date];
    for (NSString *key in [gFired.allKeys copy]) {
        NSDate *firedDate = gFired[key];
        if (![firedDate isKindOfClass:[NSDate class]] || [now timeIntervalSinceDate:firedDate] > 1209600.0) {
            [gFired removeObjectForKey:key];
        }
    }
    [gFired writeToFile:WSSMFFiredPath atomically:YES];
}

static NSString *WSSMFFiredKey(NSString *bundleID, id scheduleID, NSDate *occurrence) {
    if (!bundleID.length || !scheduleID || !occurrence) return nil;
    long long epochMS = (long long)llround([occurrence timeIntervalSince1970] * 1000.0);
    return [NSString stringWithFormat:@"%@|%@|%lld", bundleID, [scheduleID description], epochMS];
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
    NSArray<NSString *> *entries = [fm contentsOfDirectoryAtPath:WSSMFContainersRoot error:nil];
    NSMutableArray<NSDictionary *> *stores = [NSMutableArray array];

    for (NSString *entry in entries) {
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

    // Fallback for unusual container metadata: only use a container when the exact
    // Watusi schedule file exists. Avoid duplicates already identified above.
    if (stores.count == 0) {
        for (NSString *entry in entries) {
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

static NSArray *WSSMFReadSchedules(NSString *path) {
    NSDictionary *root = [NSDictionary dictionaryWithContentsOfFile:path];
    id schedules = [root isKindOfClass:[NSDictionary class]] ? root[@"schedules"] : nil;
    return [schedules isKindOfClass:[NSArray class]] ? schedules : @[];
}

static NSDate *WSSMFNextCalendarOccurrence(NSDate *base, NSString *repeat, NSDate *afterDate) {
    NSCalendar *calendar = [NSCalendar currentCalendar];
    NSCalendarUnit units = NSCalendarUnitHour | NSCalendarUnitMinute | NSCalendarUnitSecond;

    if ([repeat isEqualToString:@"Weekly"]) units |= NSCalendarUnitWeekday;
    else if ([repeat isEqualToString:@"Monthly"]) units |= NSCalendarUnitDay;
    else if ([repeat isEqualToString:@"Yearly"]) units |= NSCalendarUnitMonth | NSCalendarUnitDay;

    NSDateComponents *components = [calendar components:units fromDate:base];
    NSDate *candidate = [calendar nextDateAfterDate:afterDate
                                 matchingComponents:components
                                            options:NSCalendarMatchNextTimePreservingSmallerUnits];
    if (candidate && [candidate compare:base] == NSOrderedAscending) {
        candidate = [calendar nextDateAfterDate:base
                              matchingComponents:components
                                         options:NSCalendarMatchNextTimePreservingSmallerUnits];
    }
    return candidate;
}

static NSDate *WSSMFOccurrenceForSchedule(NSDictionary *schedule, NSDate *now, BOOL *isDue) {
    if (isDue) *isDue = NO;
    NSDate *base = [schedule[@"date"] isKindOfClass:[NSDate class]] ? schedule[@"date"] : nil;
    if (!base) return nil;

    NSString *repeat = [schedule[@"repeat"] isKindOfClass:[NSString class]] ? schedule[@"repeat"] : @"None";
    NSDate *windowStart = [now dateByAddingTimeInterval:-WSSMFGraceSeconds];
    NSDate *occurrence = nil;

    if (!repeat.length || [repeat isEqualToString:@"None"]) {
        occurrence = base;
    } else if ([repeat isEqualToString:@"Minutely"] || [repeat isEqualToString:@"Hourly"]) {
        NSTimeInterval interval = [repeat isEqualToString:@"Minutely"] ? 60.0 : 3600.0;
        if ([windowStart compare:base] == NSOrderedAscending) {
            occurrence = base;
        } else {
            NSTimeInterval elapsed = [windowStart timeIntervalSinceDate:base];
            double steps = floor(elapsed / interval) + 1.0;
            occurrence = [base dateByAddingTimeInterval:steps * interval];
        }
    } else if ([repeat isEqualToString:@"Daily"] ||
               [repeat isEqualToString:@"Weekly"] ||
               [repeat isEqualToString:@"Monthly"] ||
               [repeat isEqualToString:@"Yearly"]) {
        if ([windowStart compare:base] == NSOrderedAscending) {
            occurrence = base;
        } else {
            occurrence = WSSMFNextCalendarOccurrence(base, repeat, windowStart);
        }
    } else {
        occurrence = base;
    }

    if (!occurrence) return nil;
    NSTimeInterval delta = [now timeIntervalSinceDate:occurrence];
    if (delta >= 0.0 && delta <= WSSMFGraceSeconds) {
        if (isDue) *isDue = YES;
    }
    return occurrence;
}

static BOOL WSSMFFire(id scheduleID, NSString *bundleID, NSString **resultOut) {
    if (!scheduleID || !WSSMFIsWhatsAppBundle(bundleID)) {
        if (resultOut) *resultOut = @"invalid-schedule-or-bundle";
        return NO;
    }

    NSDictionary *runningSchedule = @{
        @"userInfo": @{ WSSMFScheduleIDKey: scheduleID },
        @"bundleID": bundleID
    };

    if (![runningSchedule writeToFile:WSSMFRunningSchedulePath atomically:YES]) {
        if (resultOut) *resultOut = @"failed-writing-running-schedule-plist";
        return NO;
    }

    uint32_t status = notify_post(WSSMFPushNotificationName);
    if (status != NOTIFY_STATUS_OK) {
        if (resultOut) *resultOut = [NSString stringWithFormat:@"notify-post-failed-%u", status];
        return NO;
    }

    if (resultOut) *resultOut = @"watusi-pushkit-bridge-posted";
    return YES;
}

static void WSSMFArmDueTimer(NSTimeInterval seconds);

static void WSSMFRefresh(NSString *reason) {
    NSDate *now = [NSDate date];
    NSArray<NSDictionary *> *stores = WSSMFScheduleStores();
    NSMutableArray<NSString *> *paths = [NSMutableArray array];
    NSUInteger totalSchedules = 0;
    NSDate *nextDue = nil;
    NSMutableDictionary *lastEvent = [NSMutableDictionary dictionary];

    for (NSDictionary *store in stores) {
        NSString *bundleID = store[@"bundleID"];
        NSString *path = store[@"schedulePath"];
        if (path.length) [paths addObject:path];

        NSArray *schedules = WSSMFReadSchedules(path);
        totalSchedules += schedules.count;

        for (id object in schedules) {
            if (![object isKindOfClass:[NSDictionary class]]) continue;
            NSDictionary *schedule = object;
            id scheduleID = schedule[@"id"] ?: schedule[@"uniqueID"];
            if (!scheduleID) continue;

            BOOL due = NO;
            NSDate *occurrence = WSSMFOccurrenceForSchedule(schedule, now, &due);
            if (!occurrence) continue;

            NSString *key = WSSMFFiredKey(bundleID, scheduleID, occurrence);
            if (due && !WSSMFAlreadyFired(key)) {
                NSString *result = nil;
                BOOL fired = WSSMFFire(scheduleID, bundleID, &result);
                if (fired) {
                    WSSMFMarkFired(key);
                    // Give WatusiSchedules in callservicesd time to consume the shared
                    // bridge plist before another due item can overwrite it.
                    usleep(500000);
                }

                lastEvent[@"lastResult"] = result ?: @"unknown";
                lastEvent[@"lastScheduleID"] = [scheduleID description];
                lastEvent[@"lastBundleID"] = bundleID ?: @"unknown";
                lastEvent[@"lastOccurrence"] = occurrence;
                lastEvent[@"lastLatenessSeconds"] = @([now timeIntervalSinceDate:occurrence]);
            }

            if ([occurrence compare:now] == NSOrderedDescending && (!nextDue || [occurrence compare:nextDue] == NSOrderedAscending)) {
                nextDue = occurrence;
            }
        }
    }

    NSTimeInterval armSeconds = WSSMFMaintenanceSeconds;
    if (nextDue) {
        armSeconds = MAX(0.1, [nextDue timeIntervalSinceDate:[NSDate date]]);
        armSeconds = MIN(armSeconds, WSSMFMaintenanceSeconds);
    }
    WSSMFArmDueTimer(armSeconds);

    NSMutableDictionary *debug = [NSMutableDictionary dictionaryWithDictionary:@{
        @"event": reason ?: @"refresh",
        @"result": @"scheduler-refreshed",
        @"storeCount": @(stores.count),
        @"scheduleCount": @(totalSchedules),
        @"storePaths": paths,
        @"nextDue": nextDue ?: @"none",
        @"nextWakeSeconds": @(armSeconds)
    }];
    [debug addEntriesFromDictionary:lastEvent];
    WSSMFWriteDebug(debug);
}

static void WSSMFArmDueTimer(NSTimeInterval seconds) {
    if (!gDueTimer) return;
    uint64_t delay = (uint64_t)(MAX(0.1, seconds) * NSEC_PER_SEC);
    dispatch_source_set_timer(gDueTimer,
                              dispatch_time(DISPATCH_TIME_NOW, (int64_t)delay),
                              DISPATCH_TIME_FOREVER,
                              100 * NSEC_PER_MSEC);
}

static void WSSMFSetup(void) {
    gQueue = dispatch_queue_create("com.551.watusischeduledmsgfix.scheduler", DISPATCH_QUEUE_SERIAL);
    WSSMFLoadFired();

    gDueTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, gQueue);
    dispatch_source_set_event_handler(gDueTimer, ^{
        WSSMFRefresh(@"due-timer");
    });
    dispatch_resume(gDueTimer);

    gMaintenanceTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, gQueue);
    dispatch_source_set_timer(gMaintenanceTimer,
                              dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC),
                              (uint64_t)(WSSMFMaintenanceSeconds * NSEC_PER_SEC),
                              1 * NSEC_PER_SEC);
    dispatch_source_set_event_handler(gMaintenanceTimer, ^{
        WSSMFRefresh(@"maintenance-timer");
    });
    dispatch_resume(gMaintenanceTimer);

    uint32_t status = notify_register_dispatch(WSSMFSchedulesChangedName, &gScheduleChangedToken, gQueue, ^(__unused int token) {
        WSSMFRefresh(@"watusi-schedules-changed");
    });

    WSSMFWriteDebug(@{
        @"event": @"daemon-start",
        @"result": status == NOTIFY_STATUS_OK ? @"notify-listener-registered" : [NSString stringWithFormat:@"notify-register-failed-%u", status]
    });

    dispatch_async(gQueue, ^{
        WSSMFRefresh(@"initial-scan");
    });
}

int main(int argc, char *argv[]) {
    @autoreleasepool {
        WSSMFSetup();
        dispatch_main();
    }
    return 0;
}
