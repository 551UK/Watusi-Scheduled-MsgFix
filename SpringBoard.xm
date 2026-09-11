#import <Foundation/Foundation.h>
#import <objc/message.h>

static NSString * const kVersion = @"1.0.6";
static NSString * const kDebugPath = @"/var/mobile/Library/Preferences/com.551.watusischeduledmsgfix-debug.plist";

static id SafeValue(id object, NSString *name) {
    if (!object || !name.length) return nil;
    SEL sel = NSSelectorFromString(name);
    @try {
        if ([object respondsToSelector:sel]) return ((id (*)(id, SEL))objc_msgSend)(object, sel);
        return [object valueForKey:name];
    } @catch (__unused NSException *e) {
        return nil;
    }
}

static void WriteDebug(NSDictionary *values) {
    NSMutableDictionary *d = [NSMutableDictionary dictionary];
    d[@"version"] = kVersion;
    d[@"date"] = [NSDate date];
    d[@"process"] = [[NSProcessInfo processInfo] processName] ?: @"unknown";
    if (values) [d addEntriesFromDictionary:values];
    [d writeToFile:kDebugPath atomically:YES];
}

static NSString *BundleIDForRequest(id request) {
    for (NSString *key in @[@"sectionIdentifier", @"sectionID", @"bundleIdentifier", @"bundleID"]) {
        id value = SafeValue(request, key);
        if ([value isKindOfClass:[NSString class]]) return value;
    }
    id bulletin = SafeValue(request, @"bulletin");
    for (NSString *key in @[@"sectionID", @"sectionIdentifier", @"publisherBulletinID"]) {
        id value = SafeValue(bulletin, key);
        if ([value isKindOfClass:[NSString class]]) return value;
    }
    return nil;
}

static void PassBulletinToWatusi(id request, NSString *hookName) {
    NSString *bundleID = BundleIDForRequest(request);
    if (bundleID && ![bundleID hasPrefix:@"net.whatsapp"]) return;

    id bulletin = SafeValue(request, @"bulletin");
    Class helper = NSClassFromString(@"WSSchedulerHelper");
    SEL check = NSSelectorFromString(@"checkBulletin:");

    if (!bulletin) {
        WriteDebug(@{@"event": @"request", @"hook": hookName ?: @"unknown", @"result": @"no-bulletin", @"bundleID": bundleID ?: @"unknown"});
        return;
    }

    if (helper && [helper respondsToSelector:check]) {
        ((void (*)(id, SEL, id))objc_msgSend)(helper, check, bulletin);
        WriteDebug(@{@"event": @"request", @"hook": hookName ?: @"unknown", @"result": @"passed-bulletin-to-watusi", @"bundleID": bundleID ?: @"unknown", @"bulletinClass": NSStringFromClass([bulletin class]) ?: @"unknown"});
        return;
    }

    WriteDebug(@{@"event": @"request", @"hook": hookName ?: @"unknown", @"result": @"watusi-checkBulletin-not-found", @"bundleID": bundleID ?: @"unknown", @"helperFound": @(helper != Nil), @"bulletinClass": NSStringFromClass([bulletin class]) ?: @"unknown"});
}

%hook CSNotificationDispatcher

- (void)postNotificationRequest:(id)request {
    PassBulletinToWatusi(request, @"CSNotificationDispatcher");
    %orig;
}

%end

%hook SBDashBoardNotificationDispatcher

- (void)postNotificationRequest:(id)request forCoalescedNotification:(id)coalescedNotification {
    PassBulletinToWatusi(request, @"SBDashBoardNotificationDispatcher");
    %orig;
}

%end

%ctor {
    @autoreleasepool {
        Class helper = NSClassFromString(@"WSSchedulerHelper");
        SEL check = NSSelectorFromString(@"checkBulletin:");
        WriteDebug(@{@"event": @"springboard-loaded", @"result": @"loaded", @"helperFound": @(helper != Nil), @"checkBulletinFound": @(helper && [helper respondsToSelector:check])});
    }
}
