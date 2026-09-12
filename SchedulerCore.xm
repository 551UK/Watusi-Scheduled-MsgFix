#import <Foundation/Foundation.h>
#import <objc/message.h>
#import <notify.h>
#import <unistd.h>

static NSString * const kVersion = @"1.0.13";
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
static const NSTimeInterval kMaxRecoveryAge = 86400.0;

static dispatch_queue_t gQueue;
static dispatch_source_t gTimer;
static NSMutableDictionary<NSString *, NSDate *> *gDispatched;
static NSUInteger gTick = 0;
static BOOL gGateInstalled = NO;
static __thread BOOL gDirectHelperCall = NO;

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
        for (NSString *fmt in @[@"yyyy-MM-dd HH:mm:ss Z", @"yyyy-MM-dd'T'HH:mm:ssZZZZZ", @"yyyy-MM-dd'T'HH:mm:ss.SSSZZZZZ"]) {
            NSDateFormatter *f = [NSDateFormatter new];
            f.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
            f.timeZone = [NSTimeZone localTimeZone];
            f.dateFormat = fmt;
            NSDate *date = [f dateFromString:value];
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

static BOOL ManualBridge(id scheduleID, NSString *bundleID, NSString **resultOut) {
    NSDictionary *info = @{@"userInfo":@{kScheduleIDKey:scheduleID},@"bundleID":bundleID};
    if (![info writeToFile:kRunningSchedulePath atomically:YES]) {
        if (resultOut) *resultOut = @"manual-bridge-write-failed";
        return NO;
    }
    uint32_t status = notify_post(kPushNotification);
    if (status != NOTIFY_STATUS_OK) {
        if (resultOut) *resultOut = [NSString stringWithFormat:@"manual-notify-failed-%u",status];
        return NO;
    }
    if (resultOut) *resultOut = @"manual-watusi-pushkit-bridge-posted";
    return YES;
}

static BOOL FireSchedule(id scheduleID, NSString *bundleID, NSString **resultOut) {
    if (!scheduleID || !IsWA(bundleID)) return NO;

    Class helper = NSClassFromString(@"WSSchedulerHelper");
    SEL sel = NSSelectorFromString(@"sendPushNotificationForScheduleID:bundleIdentifier:");
    if (helper && [helper respondsToSelector:sel]) {
        @try {
            gDirectHelperCall = YES;
            ((void (*)(id,SEL,id,id))objc_msgSend)(helper,sel,scheduleID,bundleID);
            if (resultOut) *resultOut = @"called-watusi-sendPush-helper";
            return YES;
        } @catch (__unused NSException *e) {
        } @finally {
            gDirectHelperCall = NO;
        }
    }
    return ManualBridge(scheduleID,bundleID,resultOut);
}

static void ScanSchedules(NSString *reason) {
    NSDate *now = [NSDate date];
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
            if (lateness > kMaxRecoveryAge) continue;

            NSString *key = ScheduleKey(bundleID,scheduleID,scheduledDate);
            if (!key.length || WasDispatched(key)) continue;

            NSString *result = nil;
            BOOL posted = FireSchedule(scheduleID,bundleID,&result);
            if (posted) MarkDispatched(key);

            lastEvent[@"lastResult"] = result ?: @"unknown";
            lastEvent[@"lastScheduleID"] = [scheduleID description] ?: @"unknown";
            lastEvent[@"lastBundleID"] = bundleID ?: @"unknown";
            lastEvent[@"lastScheduledDate"] = scheduledDate;
            lastEvent[@"lastLatenessSeconds"] = @(lateness);
            lastEvent[@"lastWakePosted"] = @(posted);
        }
    }

    gTick++;
    if ((gTick % 10) == 0 || lastEvent.count || [reason isEqualToString:@"scheduler-start"]) {
        NSMutableDictionary *debug = [@{@"event":reason ?: @"scan",
                                        @"result":@"springboard-direct-store-scan",
                                        @"scheduleCount":@(scheduleCount),
                                        @"rootTypes":rootTypes,
                                        @"nextDue":nextDue ?: @"none",
                                        @"helperFound":@(NSClassFromString(@"WSSchedulerHelper") != Nil),
                                        @"dispatchedCount":@(gDispatched.count)} mutableCopy];
        [debug addEntriesFromDictionary:lastEvent];
        WriteDebug(debug);
    }
}

static void StartScheduler(void) {
    LoadDispatched();
    gQueue = dispatch_queue_create("com.551.watusischeduledmsgfix.springboard",DISPATCH_QUEUE_SERIAL);
    gTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER,0,0,gQueue);
    dispatch_source_set_timer(gTimer,dispatch_time(DISPATCH_TIME_NOW,NSEC_PER_SEC),NSEC_PER_SEC,100*NSEC_PER_MSEC);
    dispatch_source_set_event_handler(gTimer,^{ ScanSchedules(@"timer-scan"); });
    dispatch_resume(gTimer);
    dispatch_async(gQueue,^{ ScanSchedules(@"scheduler-start"); });
}

%group WSSMFHelperGate
%hook WSSchedulerHelper
+ (void)sendPushNotificationForScheduleID:(id)scheduleID bundleIdentifier:(NSString *)bundleID {
    if (!gDirectHelperCall) {
        WriteGateDebug(scheduleID,bundleID,@"suppressed-watusi-native-duplicate");
        return;
    }
    WriteGateDebug(scheduleID,bundleID,@"allowed-direct-scheduler");
    %orig;
}
%end
%end

static void TryInstallHelperGate(void) {
    if (gGateInstalled) return;
    Class helper = NSClassFromString(@"WSSchedulerHelper");
    SEL sel = NSSelectorFromString(@"sendPushNotificationForScheduleID:bundleIdentifier:");
    if (helper && [helper respondsToSelector:sel]) {
        %init(WSSMFHelperGate);
        gGateInstalled = YES;
        WriteDebug(@{@"event":@"helper-gate",@"result":@"installed-direct-only"});
        return;
    }
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,500*NSEC_PER_MSEC),dispatch_get_main_queue(),^{ TryInstallHelperGate(); });
}

%ctor {
    @autoreleasepool {
        NSString *bundleID = [[NSBundle mainBundle] bundleIdentifier];
        NSString *processName = [[NSProcessInfo processInfo] processName];
        if ([bundleID isEqualToString:@"com.apple.springboard"] || [processName isEqualToString:@"SpringBoard"]) {
            dispatch_async(dispatch_get_main_queue(),^{ TryInstallHelperGate(); });
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW,2*NSEC_PER_SEC),dispatch_get_main_queue(),^{ StartScheduler(); });
        }
    }
}
