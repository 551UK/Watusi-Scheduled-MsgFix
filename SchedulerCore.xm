#import <Foundation/Foundation.h>
#import <objc/message.h>
#import <notify.h>
#import <unistd.h>

static NSString * const kVersion = @"1.0.15";
static NSString * const kWA = @"net.whatsapp.WhatsApp";
static NSString * const kWAB = @"net.whatsapp.WhatsAppSMB";
static NSString * const kScheduleIDKey = @"WatusiMessageScheduleID";
static NSString * const kScheduleRelPath = @"Library/Preferences/com.fouadraheb.watusi.scheduled-messages.plist";
static NSString * const kContainersRoot = @"/var/mobile/Containers/Data/Application";
static NSString * const kRunningSchedulePath = @"/var/mobile/Library/Preferences/com.fouadraheb.running-schedule-info.plist";
static NSString * const kDebugPath = @"/var/mobile/Library/Preferences/com.551.watusischeduledmsgfix-debug.plist";
static NSString * const kGateDebugPath = @"/var/mobile/Library/Preferences/com.551.watusischeduledmsgfix-helper-gate.plist";
static const char *kPushNotification = "com.fouadraheb.watusi.pushkit-notification";

static dispatch_queue_t gQueue;
static dispatch_source_t gTimer;
static BOOL gGateInstalled = NO;
static NSMutableDictionary *gRecentBridges;

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

// Both native notifications and the polling fallback use this same handoff.
// A void helper return is not evidence that its file was written.
static BOOL ManualBridge(id scheduleID, NSString *bundleID, NSString **resultOut) {
    @synchronized ([NSProcessInfo processInfo]) {
        if (!gRecentBridges) gRecentBridges = [NSMutableDictionary dictionary];
        NSDate *now = [NSDate date];
        for (NSString *key in [gRecentBridges.allKeys copy])
            if ([now timeIntervalSinceDate:gRecentBridges[key]] > 10.0)
                [gRecentBridges removeObjectForKey:key];
        NSString *key = [NSString stringWithFormat:@"%@|%@", bundleID, scheduleID];
        if (gRecentBridges[key]) {
            if (resultOut) *resultOut = @"handoff-already-posted";
            return YES;
        }
        // Watusi consumes one file. Never overwrite a different pending schedule.
        if ([[NSFileManager defaultManager] fileExistsAtPath:kRunningSchedulePath]) {
            NSDictionary *pending=[NSDictionary dictionaryWithContentsOfFile:kRunningSchedulePath];
            if ([pending[@"bundleID"] isEqual:bundleID] && [pending[@"userInfo"][kScheduleIDKey] isEqual:scheduleID]) {
                BOOL posted=notify_post(kPushNotification)==NOTIFY_STATUS_OK;
                if (posted) gRecentBridges[key]=now;
                if (resultOut) *resultOut=@"pending-handoff-wake-retried";
                return posted;
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
            if (resultOut) *resultOut = @"handoff-notify-failed";
            return NO;
        }
        gRecentBridges[key] = now;
        if (resultOut) *resultOut = @"handoff-posted-delivery-unconfirmed";
        return YES;
    }
}

static BOOL FireSchedule(id scheduleID, NSString *bundleID, NSString **resultOut) {
    if (!scheduleID || !IsWA(bundleID)) return NO;
    return ManualBridge(scheduleID, bundleID, resultOut);
}

static NSMutableDictionary *gLastWake;
static void ScanSchedules(void) {
    if (!gLastWake) gLastWake = [NSMutableDictionary dictionary];
    NSDate *now=[NSDate date];
    for (NSDictionary *store in ScheduleStores()) {
        NSString *path=[[store[@"schedulePath"] stringByDeletingLastPathComponent]
            stringByAppendingPathComponent:@"com.551.watusischeduledmsgfix-outbox.plist"];
        NSDictionary *rows=[NSDictionary dictionaryWithContentsOfFile:path];
        if (![rows isKindOfClass:[NSDictionary class]]) continue;
        for (NSString *key in rows) {
            NSDictionary *row=rows[key];
            if (![row isKindOfClass:[NSDictionary class]] || ![row[@"status"] isEqual:@"pending"] ||
                ![row[@"date"] isKindOfClass:[NSDate class]] || [row[@"date"] compare:now]==NSOrderedDescending || !row[@"id"]) continue;
            NSString *wakeKey=[store[@"bundleID"] stringByAppendingFormat:@"|%@",key];
            NSDate *last=gLastWake[wakeKey];
            if (last && [now timeIntervalSinceDate:last]<60) continue;
            NSString *result=nil;
            BOOL posted=FireSchedule(row[@"id"],store[@"bundleID"],&result);
            if (posted) gLastWake[wakeKey]=now;
            WriteDebug(@{@"result":result ?: @"unknown",@"wakeRequested":@(posted),@"deliveryConfirmed":@NO});
        }
    }
}
static void StartScheduler(void) {
    gQueue=dispatch_get_main_queue();
    gTimer=dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER,0,0,gQueue);
    dispatch_source_set_timer(gTimer,dispatch_time(DISPATCH_TIME_NOW,NSEC_PER_SEC),5*NSEC_PER_SEC,100*NSEC_PER_MSEC);
    dispatch_source_set_event_handler(gTimer,^{ @autoreleasepool { ScanSchedules(); } });
    dispatch_resume(gTimer);
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
