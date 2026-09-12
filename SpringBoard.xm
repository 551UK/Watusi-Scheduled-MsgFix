#import <Foundation/Foundation.h>
#import <objc/message.h>

static NSString * const kVersion = @"2.0.0";
static NSString * const kDebugPath = @"/var/mobile/Library/Preferences/com.551.watusischeduledmsgfix-native-debug.plist";
static const NSTimeInterval kDedupeWindow = 5.0;

static NSMutableDictionary<NSString *, NSDate *> *gRecentBulletins;
static NSObject *gDedupeLock;

static id SafeValue(id object, NSString *name) {
    if (!object || !name.length || object == [NSNull null]) return nil;
    SEL sel = NSSelectorFromString(name);
    @try {
        if ([object respondsToSelector:sel]) return ((id (*)(id, SEL))objc_msgSend)(object, sel);
        return [object valueForKey:name];
    } @catch (__unused NSException *e) {
        return nil;
    }
}

static void WriteDebug(NSDictionary *extra) {
    NSMutableDictionary *d = [NSMutableDictionary dictionary];
    d[@"version"] = kVersion;
    d[@"date"] = [NSDate date];
    d[@"process"] = [[NSProcessInfo processInfo] processName] ?: @"unknown";
    if (extra) [d addEntriesFromDictionary:extra];
    [d writeToFile:kDebugPath atomically:YES];
}

static NSString *BundleIDForRequest(id request) {
    for (NSString *key in @[@"sectionIdentifier", @"sectionID", @"bundleIdentifier", @"bundleID"]) {
        id value = SafeValue(request, key);
        if ([value isKindOfClass:[NSString class]] && [value length]) return value;
    }
    id bulletin = SafeValue(request, @"bulletin");
    for (NSString *key in @[@"sectionID", @"sectionIdentifier"]) {
        id value = SafeValue(bulletin, key);
        if ([value isKindOfClass:[NSString class]] && [value length]) return value;
    }
    return nil;
}

static id BulletinForRequest(id request) {
    id bulletin = SafeValue(request, @"bulletin");
    if (bulletin) return bulletin;
    id nested = SafeValue(request, @"bulletinRequest");
    return nested ? SafeValue(nested, @"bulletin") : nil;
}

static NSString *DedupeKey(id request, id bulletin) {
    NSArray *objects = bulletin ? @[bulletin, request ?: bulletin] : (request ? @[request] : @[]);
    for (id object in objects) {
        for (NSString *key in @[@"bulletinID", @"recordID", @"publisherBulletinID", @"notificationRequestIdentifier", @"requestIdentifier", @"identifier"]) {
            id value = SafeValue(object, key);
            if ([value isKindOfClass:[NSString class]] && [value length]) {
                return [NSString stringWithFormat:@"id:%@", value];
            }
        }
    }
    return [NSString stringWithFormat:@"ptr:%p", bulletin ?: request];
}

static BOOL ClaimBulletin(NSString *key) {
    if (!key.length) return YES;
    NSDate *now = [NSDate date];
    BOOL allow = YES;
    @synchronized (gDedupeLock) {
        for (NSString *oldKey in [gRecentBulletins.allKeys copy]) {
            NSDate *date = gRecentBulletins[oldKey];
            if (!date || [now timeIntervalSinceDate:date] > kDedupeWindow) [gRecentBulletins removeObjectForKey:oldKey];
        }
        NSDate *previous = gRecentBulletins[key];
        if (previous && [now timeIntervalSinceDate:previous] <= kDedupeWindow) allow = NO;
        else gRecentBulletins[key] = now;
    }
    return allow;
}

static void PassToWatusi(id request, NSString *hookName) {
    NSString *bundleID = BundleIDForRequest(request);
    if (bundleID.length && ![bundleID hasPrefix:@"net.whatsapp"]) return;

    id bulletin = BulletinForRequest(request);
    if (!bulletin) {
        WriteDebug(@{@"event":@"request", @"hook":hookName ?: @"unknown", @"result":@"no-bulletin", @"bundleID":bundleID ?: @"unknown"});
        return;
    }

    NSString *key = DedupeKey(request, bulletin);
    if (!ClaimBulletin(key)) {
        WriteDebug(@{@"event":@"request", @"hook":hookName ?: @"unknown", @"result":@"duplicate-bulletin-ignored", @"bundleID":bundleID ?: @"unknown", @"dedupeKey":key ?: @"unknown"});
        return;
    }

    Class helper = NSClassFromString(@"WSSchedulerHelper");
    SEL check = NSSelectorFromString(@"checkBulletin:");
    if (!helper || ![helper respondsToSelector:check]) {
        WriteDebug(@{@"event":@"request", @"hook":hookName ?: @"unknown", @"result":@"watusi-helper-unavailable", @"bundleID":bundleID ?: @"unknown", @"helperFound":@(helper != Nil)});
        return;
    }

    @try {
        ((id (*)(id, SEL, id))objc_msgSend)(helper, check, bulletin);
        WriteDebug(@{@"event":@"request", @"hook":hookName ?: @"unknown", @"result":@"passed-to-watusi-checkBulletin", @"bundleID":bundleID ?: @"unknown", @"bulletinClass":NSStringFromClass([bulletin class]) ?: @"unknown", @"dedupeKey":key ?: @"unknown"});
    } @catch (NSException *exception) {
        WriteDebug(@{@"event":@"request", @"hook":hookName ?: @"unknown", @"result":@"checkBulletin-exception", @"exception":exception.name ?: @"unknown"});
    }
}

%hook CSNotificationDispatcher
- (void)postNotificationRequest:(id)request {
    PassToWatusi(request, @"CSNotificationDispatcher");
    %orig;
}
%end

%hook SBDashBoardNotificationDispatcher
- (void)postNotificationRequest:(id)request forCoalescedNotification:(id)coalescedNotification {
    PassToWatusi(request, @"SBDashBoardNotificationDispatcher");
    %orig;
}
%end

%ctor {
    @autoreleasepool {
        gRecentBulletins = [NSMutableDictionary dictionary];
        gDedupeLock = [NSObject new];
        Class helper = NSClassFromString(@"WSSchedulerHelper");
        SEL check = NSSelectorFromString(@"checkBulletin:");
        WriteDebug(@{@"event":@"springboard-loaded", @"result":@"native-bridge-ready", @"helperFound":@(helper != Nil), @"checkBulletinFound":@(helper && [helper respondsToSelector:check])});
    }
}
