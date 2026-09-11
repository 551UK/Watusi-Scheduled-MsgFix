#import <Foundation/Foundation.h>
#import <objc/message.h>

static NSString * const WSSMFVersion = @"1.0.4";
static NSString * const WSSMFWhatsAppBundle = @"net.whatsapp.WhatsApp";
static NSString * const WSSMFWhatsAppBusinessBundle = @"net.whatsapp.WhatsAppSMB";
static NSString * const WSSMFScheduleIDKey = @"WatusiMessageScheduleID";
static NSString * const WSSMFDebugPath = @"/var/mobile/Library/Preferences/com.551.watusischeduledmsgfix-debug.plist";

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

static BOOL WSSMFIsWhatsAppBundle(NSString *bundleID) {
    if (![bundleID isKindOfClass:[NSString class]]) return NO;
    return [bundleID isEqualToString:WSSMFWhatsAppBundle] ||
           [bundleID isEqualToString:WSSMFWhatsAppBusinessBundle];
}

static NSString *WSSMFBundleIdentifier(id object) {
    for (NSString *name in @[@"sectionIdentifier", @"sectionID", @"bundleIdentifier", @"bundleID", @"applicationBundleIdentifier"]) {
        id value = WSSMFSafeValue(object, name);
        if ([value isKindOfClass:[NSString class]] && WSSMFIsWhatsAppBundle(value)) return value;
    }
    return nil;
}

static void WSSMFWriteDebug(NSDictionary *extra) {
    NSMutableDictionary *debug = [NSMutableDictionary dictionary];
    debug[@"version"] = WSSMFVersion;
    debug[@"date"] = [NSDate date];
    if (extra) [debug addEntriesFromDictionary:extra];
    [debug writeToFile:WSSMFDebugPath atomically:YES];
}

static id WSSMFFindScheduleID(id object, NSUInteger depth, NSString **sourceOut) {
    if (!object || object == [NSNull null] || depth > 7) return nil;

    if ([object isKindOfClass:[NSDictionary class]]) {
        NSDictionary *dictionary = (NSDictionary *)object;
        id direct = dictionary[WSSMFScheduleIDKey];
        if (direct && direct != [NSNull null]) {
            if (sourceOut) *sourceOut = @"userInfo";
            return direct;
        }

        for (NSString *key in @[@"userInfo", @"request", @"content", @"context", @"notification", @"localNotification", @"UNBulletinContextArchivedUserNotification"]) {
            id found = WSSMFFindScheduleID(dictionary[key], depth + 1, sourceOut);
            if (found) return found;
        }
        return nil;
    }

    if ([object isKindOfClass:[NSArray class]]) {
        for (id value in (NSArray *)object) {
            id found = WSSMFFindScheduleID(value, depth + 1, sourceOut);
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
            return WSSMFFindScheduleID(decoded, depth + 1, sourceOut);
        } @catch (__unused NSException *exception) {
            return nil;
        }
    }

    for (NSString *name in @[@"userInfo", @"request", @"content", @"context", @"notification"]) {
        id value = WSSMFSafeValue(object, name);
        if (!value || value == object) continue;

        if ([name isEqualToString:@"context"]) {
            Class helper = NSClassFromString(@"WSSchedulerHelper");
            SEL decoder = NSSelectorFromString(@"userInfoFromBulletinContext:");
            if (helper && [helper respondsToSelector:decoder]) {
                @try {
                    id userInfo = ((id (*)(id, SEL, id))objc_msgSend)(helper, decoder, value);
                    id found = WSSMFFindScheduleID(userInfo, depth + 1, sourceOut);
                    if (found) {
                        if (sourceOut) *sourceOut = @"WSSchedulerHelper-userInfoFromBulletinContext";
                        return found;
                    }
                } @catch (__unused NSException *exception) {}
            }
        }

        id found = WSSMFFindScheduleID(value, depth + 1, sourceOut);
        if (found) {
            if (sourceOut && (!*sourceOut || [*sourceOut isEqualToString:@"userInfo"])) {
                *sourceOut = [NSString stringWithFormat:@"%@-chain", name];
            }
            return found;
        }
    }

    return nil;
}

static NSString *WSSMFRequestIdentifier(id request) {
    for (NSString *name in @[@"notificationIdentifier", @"requestIdentifier", @"identifier"]) {
        id value = WSSMFSafeValue(request, name);
        if ([value isKindOfClass:[NSString class]] && [value length]) return value;
    }
    return [NSString stringWithFormat:@"%p", request];
}

static NSMutableDictionary<NSString *, NSDate *> *WSSMFRecentRequests(void) {
    static NSMutableDictionary<NSString *, NSDate *> *recent;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{ recent = [NSMutableDictionary dictionary]; });
    return recent;
}

static BOOL WSSMFClaimRequest(id request) {
    NSString *key = WSSMFRequestIdentifier(request);
    NSDate *now = [NSDate date];
    @synchronized (WSSMFRecentRequests()) {
        NSMutableDictionary *recent = WSSMFRecentRequests();
        for (NSString *oldKey in [recent.allKeys copy]) {
            NSDate *date = recent[oldKey];
            if (!date || [now timeIntervalSinceDate:date] > 120.0) [recent removeObjectForKey:oldKey];
        }
        NSDate *last = recent[key];
        if (last && [now timeIntervalSinceDate:last] < 120.0) return NO;
        recent[key] = now;
        return YES;
    }
}

static void WSSMFHandleModernRequest(id request, NSString *hookName) {
    NSString *bundleID = WSSMFBundleIdentifier(request);
    if (!WSSMFIsWhatsAppBundle(bundleID)) return;

    NSString *source = nil;
    id scheduleID = WSSMFFindScheduleID(request, 0, &source);
    Class helper = NSClassFromString(@"WSSchedulerHelper");
    SEL sendSelector = NSSelectorFromString(@"sendPushNotificationForScheduleID:bundleIdentifier:");

    if (!scheduleID) {
        WSSMFWriteDebug(@{
            @"event": @"modern-request",
            @"hook": hookName ?: @"unknown",
            @"result": @"schedule-id-not-found",
            @"requestClass": request ? NSStringFromClass([request class]) : @"nil",
            @"requestIdentifier": WSSMFRequestIdentifier(request),
            @"bundleID": bundleID ?: @"unknown",
            @"respondsToRequest": @([request respondsToSelector:NSSelectorFromString(@"request")]),
            @"respondsToContent": @([request respondsToSelector:NSSelectorFromString(@"content")]),
            @"respondsToContext": @([request respondsToSelector:NSSelectorFromString(@"context")]),
            @"helperFound": @(helper != Nil),
            @"helperMethodFound": @(helper && [helper respondsToSelector:sendSelector])
        });
        return;
    }

    if (!WSSMFClaimRequest(request)) return;

    if (!helper || ![helper respondsToSelector:sendSelector]) {
        WSSMFWriteDebug(@{
            @"event": @"schedule-forward",
            @"hook": hookName ?: @"unknown",
            @"result": @"watusi-helper-not-found",
            @"bundleID": bundleID ?: @"unknown",
            @"scheduleID": [scheduleID description] ?: @"unknown",
            @"scheduleIDSource": source ?: @"unknown"
        });
        return;
    }

    @try {
        ((void (*)(id, SEL, id, id))objc_msgSend)(helper, sendSelector, scheduleID, bundleID);
        WSSMFWriteDebug(@{
            @"event": @"schedule-forward",
            @"hook": hookName ?: @"unknown",
            @"result": @"called-watusi-sendPush-helper",
            @"requestClass": request ? NSStringFromClass([request class]) : @"nil",
            @"requestIdentifier": WSSMFRequestIdentifier(request),
            @"bundleID": bundleID ?: @"unknown",
            @"scheduleID": [scheduleID description] ?: @"unknown",
            @"scheduleIDSource": source ?: @"unknown",
            @"helperFound": @YES,
            @"helperMethodFound": @YES
        });
    } @catch (NSException *exception) {
        WSSMFWriteDebug(@{
            @"event": @"schedule-forward",
            @"hook": hookName ?: @"unknown",
            @"result": @"watusi-helper-threw-exception",
            @"exception": exception.name ?: @"unknown",
            @"bundleID": bundleID ?: @"unknown",
            @"scheduleID": [scheduleID description] ?: @"unknown"
        });
    }
}

%hook CSNotificationDispatcher

- (void)postNotificationRequest:(id)request {
    WSSMFHandleModernRequest(request, @"CSNotificationDispatcher");
    %orig;
}

%end

%hook SBDashBoardNotificationDispatcher

- (void)postNotificationRequest:(id)request forCoalescedNotification:(id)coalescedNotification {
    WSSMFHandleModernRequest(request, @"SBDashBoardNotificationDispatcher");
    %orig;
}

%end
