#import <Foundation/Foundation.h>
#import <objc/message.h>
#import <notify.h>

static NSString * const WSSMFWhatsAppBundle = @"net.whatsapp.WhatsApp";
static NSString * const WSSMFWhatsAppBusinessBundle = @"net.whatsapp.WhatsAppSMB";
static NSString * const WSSMFScheduleIDKey = @"WatusiMessageScheduleID";
static NSString * const WSSMFScheduleRelativePath = @"Library/Preferences/com.fouadraheb.watusi.scheduled-messages.plist";
static NSString * const WSSMFContainersRoot = @"/var/mobile/Containers/Data/Application";
static NSString * const WSSMFRunningSchedulePath = @"/var/mobile/Library/Preferences/com.fouadraheb.running-schedule-info.plist";
static NSString * const WSSMFFiredPath = @"/var/mobile/Library/Preferences/com.551.watusischeduledmsgfix-fired.plist";
static const char *WSSMFPushNotificationName = "com.fouadraheb.watusi.pushkit-notification";

static dispatch_queue_t gSchedulerQueue;
static dispatch_source_t gSchedulerTimer;
static NSMutableDictionary<NSString *, NSDate *> *gFired;

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

static NSDate *WSSMFDateFromValue(id value) {
    if ([value isKindOfClass:[NSDate class]]) return value;
    if ([value isKindOfClass:[NSNumber class]]) {
        NSTimeInterval timestamp = [value doubleValue];
        if (timestamp > 100000000000.0) timestamp /= 1000.0;
        return [NSDate dateWithTimeIntervalSince1970:timestamp];
    }
    if ([value isKindOfClass:[NSString class]]) {
        for (NSString *format in @[@"yyyy-MM-dd HH:mm:ss Z", @"yyyy-MM-dd'T'HH:mm:ssZZZZZ", @"yyyy-MM-dd'T'HH:mm:ss.SSSZZZZZ"]) {
            NSDateFormatter *formatter = [[NSDateFormatter alloc] init];
            formatter.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
            formatter.timeZone = [NSTimeZone localTimeZone];
            formatter.dateFormat = format;
            NSDate *date = [formatter dateFromString:value];
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
    long long milliseconds = (long long)llround([date timeIntervalSince1970] * 1000.0);
    return [NSString stringWithFormat:@"%@|%@|%lld", bundleID, [scheduleID description], milliseconds];
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
    NSFileManager *fileManager = [NSFileManager defaultManager];
    NSArray<NSString *> *containers = [fileManager contentsOfDirectoryAtPath:WSSMFContainersRoot error:nil];
    NSMutableArray<NSDictionary *> *stores = [NSMutableArray array];
    for (NSString *entry in containers ?: @[]) {
        NSString *containerPath = [WSSMFContainersRoot stringByAppendingPathComponent:entry];
        NSString *metadataPath = [containerPath stringByAppendingPathComponent:@".com.apple.mobile_container_manager.metadata.plist"];
        NSDictionary *metadata = [NSDictionary dictionaryWithContentsOfFile:metadataPath];
        NSString *bundleID = [metadata[@"MCMMetadataIdentifier"] isKindOfClass:[NSString class]] ? metadata[@"MCMMetadataIdentifier"] : nil;
        if (!WSSMFIsWhatsAppBundle(bundleID)) continue;
        [stores addObject:@{
            @"bundleID": bundleID,
            @"schedulePath": [containerPath stringByAppendingPathComponent:WSSMFScheduleRelativePath]
        }];
    }
    if (stores.count == 0) {
        for (NSString *entry in containers ?: @[]) {
            NSString *containerPath = [WSSMFContainersRoot stringByAppendingPathComponent:entry];
            NSString *schedulePath = [containerPath stringByAppendingPathComponent:WSSMFScheduleRelativePath];
            if ([fileManager fileExistsAtPath:schedulePath]) {
                [stores addObject:@{@"bundleID": WSSMFWhatsAppBundle, @"schedulePath": schedulePath}];
            }
        }
    }
    return stores;
}

static NSArray *WSSMFReadSchedules(NSString *path) {
    id root = [NSDictionary dictionaryWithContentsOfFile:path];
    if (!root) root = [NSArray arrayWithContentsOfFile:path];
    if ([root isKindOfClass:[NSArray class]]) return root;
    if ([root isKindOfClass:[NSDictionary class]]) {
        id schedules = ((NSDictionary *)root)[@"schedules"];
        if ([schedules isKindOfClass:[NSArray class]]) return schedules;
    }
    return @[];
}

static BOOL WSSMFManualBridge(id scheduleID, NSString *bundleID) {
    NSDictionary *runningSchedule = @{
        @"userInfo": @{WSSMFScheduleIDKey: scheduleID},
        @"bundleID": bundleID
    };
    if (![runningSchedule writeToFile:WSSMFRunningSchedulePath atomically:YES]) return NO;
    return notify_post(WSSMFPushNotificationName) == NOTIFY_STATUS_OK;
}

static BOOL WSSMFFire(id scheduleID, NSString *bundleID) {
    if (!scheduleID || !WSSMFIsWhatsAppBundle(bundleID)) return NO;
    Class helper = NSClassFromString(@"WSSchedulerHelper");
    SEL selector = NSSelectorFromString(@"sendPushNotificationForScheduleID:bundleIdentifier:");
    if (helper && [helper respondsToSelector:selector]) {
        @try {
            ((void (*)(id, SEL, id, id))objc_msgSend)(helper, selector, scheduleID, bundleID);
            return YES;
        } @catch (__unused NSException *exception) {
        }
    }
    return WSSMFManualBridge(scheduleID, bundleID);
}

static void WSSMFScanSchedules(void) {
    NSDate *now = [NSDate date];
    for (NSDictionary *store in WSSMFScheduleStores()) {
        NSString *bundleID = store[@"bundleID"];
        for (id object in WSSMFReadSchedules(store[@"schedulePath"])) {
            if (![object isKindOfClass:[NSDictionary class]]) continue;
            NSDictionary *schedule = (NSDictionary *)object;
            id scheduleID = schedule[@"id"] ?: schedule[@"uniqueID"];
            NSDate *scheduledDate = WSSMFDateFromValue(schedule[@"date"]);
            if (!scheduleID || !scheduledDate) continue;
            NSTimeInterval lateness = [now timeIntervalSinceDate:scheduledDate];
            if (lateness < 0.0 || lateness > 180.0) continue;
            NSString *firedKey = WSSMFFiredKey(bundleID, scheduleID, scheduledDate);
            if (WSSMFAlreadyFired(firedKey)) continue;
            if (WSSMFFire(scheduleID, bundleID)) WSSMFMarkFired(firedKey);
        }
    }
}

static void WSSMFStartScheduler(void) {
    WSSMFLoadFired();
    gSchedulerQueue = dispatch_queue_create("com.551.watusischeduledmsgfix.scheduler", DISPATCH_QUEUE_SERIAL);
    gSchedulerTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, gSchedulerQueue);
    dispatch_source_set_timer(gSchedulerTimer, dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC), NSEC_PER_SEC, 100 * NSEC_PER_MSEC);
    dispatch_source_set_event_handler(gSchedulerTimer, ^{ WSSMFScanSchedules(); });
    dispatch_resume(gSchedulerTimer);
}

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
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{ WSSMFStartScheduler(); });
        }
    }
}
