#import <Foundation/Foundation.h>
#import <objc/message.h>
#import <notify.h>
#import <unistd.h>

static NSString * const kVersion = @"1.0.16";
static NSString * const kWA = @"net.whatsapp.WhatsApp";
static NSString * const kWAB = @"net.whatsapp.WhatsAppSMB";
static NSString * const kScheduleIDKey = @"WatusiMessageScheduleID";
static NSString * const kScheduleRelPath = @"Library/Preferences/com.fouadraheb.watusi.scheduled-messages.plist";
static NSString * const kContainersRoot = @"/var/mobile/Containers/Data/Application";
static NSString * const kRunningSchedulePath = @"/var/mobile/Library/Preferences/com.fouadraheb.running-schedule-info.plist";
static NSString * const kDebugPath = @"/var/mobile/Library/Preferences/com.551.watusischeduledmsgfix-debug.plist";
static NSString * const kGateDebugPath = @"/var/mobile/Library/Preferences/com.551.watusischeduledmsgfix-helper-gate.plist";
static NSString * const kDispatchedPath = @"/var/mobile/Library/Preferences/com.551.watusischeduledmsgfix-dispatched.plist";
static const char *kPushNotification = "com.fouadraheb.watusi.pushkit-notification";
static const NSTimeInterval kRetryInterval = 15.0;
static const NSTimeInterval kMaxRecoveryAge = 86400.0;
static const NSTimeInterval kHandoffDedupeWindow = 60.0;

static dispatch_queue_t gQueue;
static dispatch_source_t gTimer;
static BOOL gGateInstalled = NO;
static NSMutableDictionary<NSString *, NSDate *> *gRecentBridges;
static NSMutableDictionary<NSString *, NSDate *> *gLastAttempt;
static NSMutableDictionary<NSString *, NSNumber *> *gAttemptCount;
static NSMutableDictionary<NSString *, NSDate *> *gDispatched;
static NSUInteger gTick = 0;

static BOOL IsWA(NSString *bundleID) {
    return [bundleID isKindOfClass:[NSString class]] &&
           ([bundleID isEqualToString:kWA] || [bundleID isEqualToString:kWAB]);
}

static void WriteDebug(NSDictionary *extra) {
    NSMutableDictionary *d = [NSMutableDictionary dictionary];
    d[@"version"] = kVersion;
    d[@"date"] = [NSDate date];
    d[@"pid"] = @((int)getpid());
    d[@"process"] = [[NSProcessInfo processInfo] processName] ?: @"unknown";
    if (extra) [d addEntriesFromDictionary:extra];
    [d writeToFile:kDebugPath atomically:YES];
}

static void WriteGateDebug(id scheduleID, NSString *bundleID, NSString *result) {
    [@{
        @"version": kVersion,
        @"date": [NSDate date],
        @"scheduleID": scheduleID ? [scheduleID description] : @"nil",
        @"bundleID": bundleID ?: @"unknown",
        @"result": result ?: @"unknown"
    } writeToFile:kGateDebugPath atomically:YES];
}

static NSDate *DateFromValue(id value) {
    if ([value isKindOfClass:[NSDate class]]) return value;
    if ([value isKindOfClass:[NSNumber class]]) {
        NSTimeInterval n = [value doubleValue];
        if (n > 100000000000.0) n /= 1000.0;
        return [NSDate dateWithTimeIntervalSince1970:n];
    }
    if ([value isKindOfClass:[NSString class]]) {
        for (NSString *format in @[@"yyyy-MM-dd HH:mm:ss Z", @"yyyy-MM-dd'T'HH:mm:ssZZZZZ", @"yyyy-MM-dd'T'HH:mm:ss.SSSZZZZZ"]) {
            NSDateFormatter *formatter = [NSDateFormatter new];
            formatter.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
            formatter.timeZone = [NSTimeZone localTimeZone];
            formatter.dateFormat = format;
            NSDate *date = [formatter dateFromString:value];
            if (date) return date;
        }
    }
    return nil;
}

static NSString *ScheduleKey(NSString *bundleID, id scheduleID, NSDate *date) {
    if (!bundleID.length || !scheduleID || !date) return nil;
    long long ms = (long long)llround([date timeIntervalSince1970] * 1000.0);
    return [NSString stringWithFormat:@"%@|%@|%lld", bundleID, [scheduleID description], ms];
}

static void LoadDispatched(void) {
    NSDictionary *stored = [NSDictionary dictionaryWithContentsOfFile:kDispatchedPath];
    gDispatched = stored ? [stored mutableCopy] : [NSMutableDictionary dictionary];
}

static BOOL WasDispatched(NSString *key) {
    if (!gDispatched) LoadDispatched();
    return key.length && gDispatched[key] != nil;
}

static void MarkDispatched(NSString *key) {
    if (!key.length) return;
    if (!gDispatched) LoadDispatched();
    gDispatched[key] = [NSDate date];
    [gDispatched writeToFile:kDispatchedPath atomically:YES];
}

static NSArray<NSDictionary *> *ScheduleStores(void) {
    NSFileManager *fm = [NSFileManager defaultManager];
    NSArray<NSString *> *entries = [fm contentsOfDirectoryAtPath:kContainersRoot error:nil];
    NSMutableArray<NSDictionary *> *stores = [NSMutableArray array];

    for (NSString *entry in entries ?: @[]) {
        NSString *container = [kContainersRoot stringByAppendingPathComponent:entry];
        NSDictionary *meta = [NSDictionary dictionaryWithContentsOfFile:[container stringByAppendingPathComponent:@".com.apple.mobile_container_manager.metadata.plist"]];
        NSString *bundleID = [meta[@"MCMMetadataIdentifier"] isKindOfClass:[NSString class]] ? meta[@"MCMMetadataIdentifier"] : nil;
        if (!IsWA(bundleID)) continue;
        [stores addObject:@{@"bundleID":bundleID,
                            @"schedulePath":[container stringByAppendingPathComponent:kScheduleRelPath]}];
    }

    if (!stores.count) {
        for (NSString *entry in entries ?: @[]) {
            NSString *container = [kContainersRoot stringByAppendingPathComponent:entry];
            NSString *path = [container stringByAppendingPathComponent:kScheduleRelPath];
            if ([fm fileExistsAtPath:path]) [stores addObject:@{@"bundleID":kWA,@"schedulePath":path}];
        }
    }
    return stores;
}

static NSArray *ReadSchedules(NSString *path, NSString **rootTypeOut) {
    id root = [NSDictionary dictionaryWithContentsOfFile:path];
    if (!root) root = [NSArray arrayWithContentsOfFile:path];
    if ([root isKindOfClass:[NSArray class]]) {
        if (rootTypeOut) *rootTypeOut = @"array";
        return root;
    }
    if ([root isKindOfClass:[NSDictionary class]]) {
        for (NSString *key in @[@"schedules", @"scheduledMessages", @"messages", @"items"]) {
            id value = root[key];
            if ([value isKindOfClass:[NSArray class]]) {
                if (rootTypeOut) *rootTypeOut = [@"dictionary:" stringByAppendingString:key];
                return value;
            }
        }
        if (rootTypeOut) *rootTypeOut = @"dictionary:no-array-key";
    }
    return @[];
}

// All scheduler paths converge here. If Watusi's native timer and our fallback
// arrive together, only the first one posts the PushKit wake.
static BOOL ManualBridge(id scheduleID, NSString *bundleID, NSString **resultOut) {
    if (!scheduleID || !IsWA(bundleID)) return NO;

    @synchronized ([NSProcessInfo processInfo]) {
        if (!gRecentBridges) gRecentBridges = [NSMutableDictionary dictionary];
        NSDate *now = [NSDate date];
        for (NSString *oldKey in [gRecentBridges.allKeys copy]) {
            NSDate *date = gRecentBridges[oldKey];
            if (!date || [now timeIntervalSinceDate:date] > kHandoffDedupeWindow)
                [gRecentBridges removeObjectForKey:oldKey];
        }

        NSString *key = [NSString stringWithFormat:@"%@|%@", bundleID, [scheduleID description]];
        if (gRecentBridges[key]) {
            if (resultOut) *resultOut = @"duplicate-handoff-suppressed";
            return YES;
        }

        if ([[NSFileManager defaultManager] fileExistsAtPath:kRunningSchedulePath]) {
            NSDictionary *pending = [NSDictionary dictionaryWithContentsOfFile:kRunningSchedulePath];
            id pendingID = [pending[@"userInfo"] isKindOfClass:[NSDictionary class]] ? pending[@"userInfo"][kScheduleIDKey] : nil;
            if ([pending[@"bundleID"] isEqual:bundleID] && [pendingID isEqual:scheduleID]) {
                gRecentBridges[key] = now;
                if (resultOut) *resultOut = @"same-handoff-already-pending";
                return YES;
            }
            if (resultOut) *resultOut = @"handoff-busy-waiting-for-consumer";
            return NO;
        }

        NSDictionary *info = @{@"userInfo":@{kScheduleIDKey:scheduleID},@"bundleID":bundleID};
        NSData *data = [NSPropertyListSerialization dataWithPropertyList:info
            format:NSPropertyListBinaryFormat_v1_0 options:0 error:nil];
        if (!data || ![data writeToFile:kRunningSchedulePath
                options:(NSDataWritingAtomic | NSDataWritingFileProtectionNone) error:nil]) {
            if (resultOut) *resultOut = @"handoff-write-failed";
            return NO;
        }

        [[NSFileManager defaultManager] setAttributes:@{NSFilePosixPermissions:@0600}
            ofItemAtPath:kRunningSchedulePath error:nil];

        uint32_t status = notify_post(kPushNotification);
        if (status != NOTIFY_STATUS_OK) {
            [[NSFileManager defaultManager] removeItemAtPath:kRunningSchedulePath error:nil];
            if (resultOut) *resultOut = [NSString stringWithFormat:@"handoff-notify-failed-%u",status];
            return NO;
        }

        gRecentBridges[key] = now;
        if (resultOut) *resultOut = @"handoff-posted";
        return YES;
    }
}

static void ScanSchedules(NSString *reason) {
    NSDate *now = [NSDate date];
    NSMutableSet<NSString *> *activeKeys = [NSMutableSet set];
    NSMutableDictionary *lastEvent = [NSMutableDictionary dictionary];
    NSMutableArray *rootTypes = [NSMutableArray array];
    NSUInteger scheduleCount = 0;
    NSDate *nextDue = nil;

    for (NSDictionary *store in ScheduleStores()) {
        NSString *bundleID = store[@"bundleID"];
        NSString *rootType = nil;
        NSArray *schedules = ReadSchedules(store[@"schedulePath"], &rootType);
        [rootTypes addObject:rootType ?: @"unknown"];
        scheduleCount += schedules.count;

        for (id object in schedules) {
            if (![object isKindOfClass:[NSDictionary class]]) continue;
            id scheduleID = object[@"id"] ?: object[@"uniqueID"];
            NSDate *scheduledDate = DateFromValue(object[@"date"]);
            if (!scheduleID || !scheduledDate) continue;

            NSTimeInterval lateness = [now timeIntervalSinceDate:scheduledDate];
            if (lateness < 0) {
                if (!nextDue || [scheduledDate compare:nextDue] == NSOrderedAscending) nextDue = scheduledDate;
                continue;
            }

            NSString *key = ScheduleKey(bundleID, scheduleID, scheduledDate);
            if (!key.length) continue;
            [activeKeys addObject:key];
            if (WasDispatched(key)) continue;
            if (lateness > kMaxRecoveryAge) continue;

            NSDate *last = gLastAttempt[key];
            if (last && [now timeIntervalSinceDate:last] < kRetryInterval) continue;
            gLastAttempt[key] = now;
            gAttemptCount[key] = @([gAttemptCount[key] unsignedIntegerValue] + 1);

            NSString *result = nil;
            BOOL posted = ManualBridge(scheduleID, bundleID, &result);
            if (posted) {
                MarkDispatched(key);
                [gLastAttempt removeObjectForKey:key];
                [gAttemptCount removeObjectForKey:key];
            }

            lastEvent[@"lastResult"] = result ?: @"unknown";
            lastEvent[@"lastScheduleID"] = [scheduleID description] ?: @"unknown";
            lastEvent[@"lastBundleID"] = bundleID ?: @"unknown";
            lastEvent[@"lastScheduledDate"] = scheduledDate;
            lastEvent[@"lastLatenessSeconds"] = @(lateness);
            lastEvent[@"lastWakePosted"] = @(posted);
            lastEvent[@"markedDispatched"] = @(posted);
        }
    }

    for (NSString *key in [gLastAttempt.allKeys copy]) {
        if (![activeKeys containsObject:key]) {
            [gLastAttempt removeObjectForKey:key];
            [gAttemptCount removeObjectForKey:key];
        }
    }

    gTick++;
    if ((gTick % 10) == 0 || lastEvent.count || [reason isEqualToString:@"scheduler-start"]) {
        NSMutableDictionary *debug = [@{
            @"event": reason ?: @"scan",
            @"result": @"direct-watusi-store-scan-with-shared-handoff-gate",
            @"scheduleCount": @(scheduleCount),
            @"rootTypes": rootTypes,
            @"nextDue": nextDue ?: @"none",
            @"helperGateInstalled": @(gGateInstalled),
            @"retryInterval": @(kRetryInterval),
            @"dispatchedCount": @(gDispatched.count)
        } mutableCopy];
        [debug addEntriesFromDictionary:lastEvent];
        WriteDebug(debug);
    }
}

static void StartScheduler(void) {
    gLastAttempt = [NSMutableDictionary dictionary];
    gAttemptCount = [NSMutableDictionary dictionary];
    LoadDispatched();
    gQueue = dispatch_queue_create("com.551.watusischeduledmsgfix.springboard", DISPATCH_QUEUE_SERIAL);
    gTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, gQueue);
    dispatch_source_set_timer(gTimer,
                              dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC),
                              NSEC_PER_SEC,
                              100 * NSEC_PER_MSEC);
    dispatch_source_set_event_handler(gTimer, ^{
        @autoreleasepool { ScanSchedules(@"timer-scan"); }
    });
    dispatch_resume(gTimer);
    dispatch_async(gQueue, ^{
        @autoreleasepool { ScanSchedules(@"scheduler-start"); }
    });
}

%group WSSMFHelperGate
%hook WSSchedulerHelper

+ (void)sendCallKitNotificationWithUserInfo:(id)userInfo bundleIdentifier:(NSString *)bundleID {
    id scheduleID = [userInfo isKindOfClass:[NSDictionary class]] ? userInfo[kScheduleIDKey] : nil;
    if (!IsWA(bundleID) || !scheduleID) {
        %orig;
        return;
    }

    NSString *result = nil;
    ManualBridge(scheduleID, bundleID, &result);
    WriteGateDebug(scheduleID, bundleID, result);
}

%end
%end

static void TryInstallHelperGate(void) {
    if (gGateInstalled) return;
    Class helper = NSClassFromString(@"WSSchedulerHelper");
    SEL sel = NSSelectorFromString(@"sendCallKitNotificationWithUserInfo:bundleIdentifier:");
    if (helper && [helper respondsToSelector:sel]) {
        %init(WSSMFHelperGate);
        gGateInstalled = YES;
        WriteDebug(@{@"event":@"helper-gate",@"result":@"installed-shared-handoff"});
        return;
    }
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 500 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{
        TryInstallHelperGate();
    });
}

%ctor {
    @autoreleasepool {
        NSString *bundleID = [[NSBundle mainBundle] bundleIdentifier];
        NSString *processName = [[NSProcessInfo processInfo] processName];
        if ([bundleID isEqualToString:@"com.apple.springboard"] || [processName isEqualToString:@"SpringBoard"]) {
            dispatch_async(dispatch_get_main_queue(), ^{ TryInstallHelperGate(); });
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{ StartScheduler(); });
        }
    }
}
