#import <Foundation/Foundation.h>
#import <notify.h>

static NSString * const WSSMFWhatsAppBundle = @"net.whatsapp.WhatsApp";
static NSString * const WSSMFWhatsAppBusinessBundle = @"net.whatsapp.WhatsAppSMB";
static NSString * const WSSMFScheduleIDKey = @"WatusiMessageScheduleID";
static NSString * const WSSMFRunningSchedulePath = @"/var/mobile/Library/Preferences/com.fouadraheb.running-schedule-info.plist";
static NSString * const WSSMFDebugPath = @"/var/mobile/Library/Preferences/com.551.watusischeduledmsgfix-debug.plist";
static const char *WSSMFPushNotificationName = "com.fouadraheb.watusi.pushkit-notification";

static id WSSMFSafeValue(id object, NSString *name) {
    if (!object || !name.length) return nil;

    SEL selector = NSSelectorFromString(name);
    @try {
        if ([object respondsToSelector:selector]) {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
            return [object performSelector:selector];
#pragma clang diagnostic pop
        }

        return [object valueForKey:name];
    } @catch (__unused NSException *exception) {
        return nil;
    }
}

static BOOL WSSMFIsWhatsAppBundle(NSString *bundleID) {
    if (![bundleID isKindOfClass:[NSString class]]) return NO;
    return [bundleID isEqualToString:WSSMFWhatsAppBundle] ||
           [bundleID isEqualToString:WSSMFWhatsAppBusinessBundle];
}

static NSString *WSSMFBundleIdentifier(id object) {
    if ([object isKindOfClass:[NSString class]]) {
        return WSSMFIsWhatsAppBundle(object) ? object : nil;
    }

    for (NSString *name in @[@"sectionIdentifier", @"bundleIdentifier", @"bundleID", @"applicationBundleIdentifier"]) {
        id value = WSSMFSafeValue(object, name);
        if ([value isKindOfClass:[NSString class]] && WSSMFIsWhatsAppBundle(value)) {
            return value;
        }
    }

    id content = WSSMFSafeValue(object, @"content");
    if (content && content != object) {
        for (NSString *name in @[@"sectionIdentifier", @"bundleIdentifier", @"bundleID"]) {
            id value = WSSMFSafeValue(content, name);
            if ([value isKindOfClass:[NSString class]] && WSSMFIsWhatsAppBundle(value)) {
                return value;
            }
        }
    }

    return nil;
}

static id WSSMFFindScheduleID(id object, NSUInteger depth) {
    if (!object || depth > 5 || object == [NSNull null]) return nil;

    if ([object isKindOfClass:[NSDictionary class]]) {
        NSDictionary *dictionary = (NSDictionary *)object;
        id direct = dictionary[WSSMFScheduleIDKey];
        if (direct && direct != [NSNull null]) return direct;

        NSArray *preferredKeys = @[@"userInfo", @"context", @"content", @"notification", @"request", @"UNBulletinContextArchivedUserNotification"];
        for (NSString *key in preferredKeys) {
            id value = dictionary[key];
            id found = WSSMFFindScheduleID(value, depth + 1);
            if (found) return found;
        }

        for (id value in dictionary.allValues) {
            if ([value isKindOfClass:[NSDictionary class]] ||
                [value isKindOfClass:[NSArray class]] ||
                [value isKindOfClass:[NSData class]]) {
                id found = WSSMFFindScheduleID(value, depth + 1);
                if (found) return found;
            }
        }
        return nil;
    }

    if ([object isKindOfClass:[NSArray class]]) {
        for (id value in (NSArray *)object) {
            id found = WSSMFFindScheduleID(value, depth + 1);
            if (found) return found;
        }
        return nil;
    }

    if ([object isKindOfClass:[NSData class]]) {
        @try {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
            id decoded = [NSKeyedUnarchiver unarchiveObjectWithData:(NSData *)object];
#pragma clang diagnostic pop
            return WSSMFFindScheduleID(decoded, depth + 1);
        } @catch (__unused NSException *exception) {
            return nil;
        }
    }

    for (NSString *name in @[@"userInfo", @"content", @"context"]) {
        id value = WSSMFSafeValue(object, name);
        if (value && value != object) {
            id found = WSSMFFindScheduleID(value, depth + 1);
            if (found) return found;
        }
    }

    return nil;
}

static NSString *WSSMFRequestIdentifier(id request) {
    for (NSString *name in @[@"notificationIdentifier", @"requestIdentifier", @"identifier"]) {
        id value = WSSMFSafeValue(request, name);
        if ([value isKindOfClass:[NSString class]]) return value;
    }
    return nil;
}

static id WSSMFScheduleIDFromRequest(id request) {
    id scheduleID = WSSMFFindScheduleID(request, 0);
    if (scheduleID) return scheduleID;

    // Watusi creates each local notification as "schedule-<uniqueID>".
    // Use that as a fallback if iOS 16's modern notification object no longer
    // exposes the original userInfo dictionary directly.
    NSString *identifier = WSSMFRequestIdentifier(request);
    if ([identifier hasPrefix:@"schedule-"] && identifier.length > 9) {
        return [identifier substringFromIndex:9];
    }

    return nil;
}

static void WSSMFWriteDebug(NSString *hook, id request, NSString *bundleID, id scheduleID, NSString *result) {
    NSMutableDictionary *debug = [NSMutableDictionary dictionary];
    debug[@"date"] = [NSDate date];
    debug[@"version"] = @"1.0.1";
    debug[@"hook"] = hook ?: @"unknown";
    debug[@"requestClass"] = request ? NSStringFromClass([request class]) : @"nil";
    debug[@"bundleID"] = bundleID ?: @"unknown";
    debug[@"scheduleID"] = scheduleID ? [scheduleID description] : @"not-found";
    debug[@"requestIdentifier"] = WSSMFRequestIdentifier(request) ?: @"not-found";
    debug[@"result"] = result ?: @"unknown";
    [debug writeToFile:WSSMFDebugPath atomically:YES];
}

static NSMutableDictionary<NSString *, NSDate *> *WSSMFRecentSchedules(void) {
    static NSMutableDictionary<NSString *, NSDate *> *recent;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        recent = [NSMutableDictionary dictionary];
    });
    return recent;
}

static BOOL WSSMFClaimSchedule(id scheduleID, NSString *bundleID) {
    NSString *key = [NSString stringWithFormat:@"%@|%@", bundleID ?: @"", [scheduleID description] ?: @""];
    NSDate *now = [NSDate date];

    @synchronized (WSSMFRecentSchedules()) {
        NSMutableDictionary *recent = WSSMFRecentSchedules();
        NSArray *keys = [recent.allKeys copy];
        for (NSString *oldKey in keys) {
            NSDate *date = recent[oldKey];
            if (!date || [now timeIntervalSinceDate:date] > 120.0) {
                [recent removeObjectForKey:oldKey];
            }
        }

        NSDate *last = recent[key];
        if (last && [now timeIntervalSinceDate:last] < 120.0) {
            return NO;
        }

        recent[key] = now;
        return YES;
    }
}

static void WSSMFReleaseScheduleClaim(id scheduleID, NSString *bundleID) {
    NSString *key = [NSString stringWithFormat:@"%@|%@", bundleID ?: @"", [scheduleID description] ?: @""];
    @synchronized (WSSMFRecentSchedules()) {
        [WSSMFRecentSchedules() removeObjectForKey:key];
    }
}

static BOOL WSSMFForwardSchedule(id request, NSString *hookName) {
    NSString *bundleID = WSSMFBundleIdentifier(request);
    if (!WSSMFIsWhatsAppBundle(bundleID)) return NO;

    id scheduleID = WSSMFScheduleIDFromRequest(request);
    if (!scheduleID) {
        // No message contents are logged. This is only to show that the modern
        // iOS 16 WhatsApp notification path was reached during testing.
        WSSMFWriteDebug(hookName, request, bundleID, nil, @"whatsapp-request-no-schedule-id");
        return NO;
    }

    if (!WSSMFClaimSchedule(scheduleID, bundleID)) {
        WSSMFWriteDebug(hookName, request, bundleID, scheduleID, @"duplicate-suppressed");
        return YES;
    }

    NSDictionary *pushUserInfo = @{ WSSMFScheduleIDKey: scheduleID };
    NSDictionary *runningSchedule = @{
        @"userInfo": pushUserInfo,
        @"bundleID": bundleID
    };

    BOOL wrote = [runningSchedule writeToFile:WSSMFRunningSchedulePath atomically:YES];
    if (!wrote) {
        WSSMFReleaseScheduleClaim(scheduleID, bundleID);
        WSSMFWriteDebug(hookName, request, bundleID, scheduleID, @"failed-writing-running-schedule-plist");
        return NO;
    }

    uint32_t notifyResult = notify_post(WSSMFPushNotificationName);
    if (notifyResult != NOTIFY_STATUS_OK) {
        WSSMFReleaseScheduleClaim(scheduleID, bundleID);
        WSSMFWriteDebug(hookName, request, bundleID, scheduleID,
                        [NSString stringWithFormat:@"notify-post-failed-%u", notifyResult]);
        return NO;
    }

    WSSMFWriteDebug(hookName, request, bundleID, scheduleID, @"forwarded-to-watusi-pushkit-bridge");
    return YES;
}

// iOS 16 modern notification route. WatusiSB hooks these same methods for its
// notification-image feature, but unlike its older bulletin hooks it never
// calls the scheduled-message helper here. We add the missing bridge.
%hook CSNotificationDispatcher

- (void)postNotificationRequest:(id)request {
    WSSMFForwardSchedule(request, @"CSNotificationDispatcher");
    %orig;
}

%end

%hook SBDashBoardNotificationDispatcher

- (void)postNotificationRequest:(id)request forCoalescedNotification:(id)coalescedNotification {
    WSSMFForwardSchedule(request, @"SBDashBoardNotificationDispatcher");
    %orig;
}

%end

// Keep the v1.0.0 safeguard too. It was not enough by itself because the
// scheduler trigger was missing, but it can still help once callservicesd is
// actually asked to wake WhatsApp.
%hook CSDVoIPApplicationController

- (BOOL)_isApplicationPreventedFromBeingLaunched:(id)application {
    NSString *bundleID = WSSMFBundleIdentifier(application);
    if (WSSMFIsWhatsAppBundle(bundleID)) {
        return NO;
    }
    return %orig;
}

%end
