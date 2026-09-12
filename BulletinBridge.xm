#import <Foundation/Foundation.h>
#import <objc/message.h>

static NSString * const kDebug = @"/var/mobile/Library/Preferences/com.551.watusischeduledmsgfix-debug.plist";
static NSString * const kScheduleKey = @"WatusiMessageScheduleID";
static NSMutableDictionary *gRecent;
static NSObject *gLock;
static BOOL gObserverInstalled = NO;

static id Value(id obj, NSString *name) {
    if (!obj || !name.length) return nil;
    @try {
        SEL sel = NSSelectorFromString(name);
        if ([obj respondsToSelector:sel]) return ((id(*)(id,SEL))objc_msgSend)(obj,sel);
        return [obj valueForKey:name];
    } @catch (__unused NSException *e) { return nil; }
}

static BOOL IsWhatsApp(NSString *bundle) {
    return [bundle isKindOfClass:[NSString class]] &&
        ([bundle isEqualToString:@"net.whatsapp.WhatsApp"] ||
         [bundle isEqualToString:@"net.whatsapp.WhatsAppSMB"]);
}

static NSString *BundleForBulletin(id bulletin) {
    for (NSString *key in @[@"sectionID", @"sectionIdentifier", @"bundleIdentifier"]) {
        id value = Value(bulletin,key);
        if ([value isKindOfClass:[NSString class]] && IsWhatsApp(value)) return value;
    }
    return nil;
}

static void LogEvent(NSDictionary *fields) {
    if (!gLock) return;
    @synchronized(gLock) {
        NSDictionary *old = [NSDictionary dictionaryWithContentsOfFile:kDebug];
        NSMutableArray *events = [NSMutableArray array];
        if ([old[@"events"] isKindOfClass:[NSArray class]]) [events addObjectsFromArray:old[@"events"]];
        NSMutableDictionary *event = [NSMutableDictionary dictionaryWithDictionary:fields ?: @{}];
        event[@"date"] = [NSDate date];
        [events addObject:event];
        while (events.count > 30) [events removeObjectAtIndex:0];
        [@{@"version":@"3.0.2", @"date":[NSDate date], @"events":events} writeToFile:kDebug atomically:YES];
    }
}

static void BackgroundWakeNow(NSString *bundle, id sid) {
    if (!IsWhatsApp(bundle)) return;

    Class optionsClass = NSClassFromString(@"FBSOpenApplicationOptions");
    Class serviceClass = NSClassFromString(@"FBSSystemService");
    SEL optionsSel = NSSelectorFromString(@"optionsWithDictionary:");
    SEL sharedSel = NSSelectorFromString(@"sharedService");
    SEL openSel = NSSelectorFromString(@"openApplication:options:withResult:");

    BOOL optionsReady = optionsClass && [optionsClass respondsToSelector:optionsSel];
    BOOL serviceReady = serviceClass && [serviceClass respondsToSelector:sharedSel];

    if (!optionsReady || !serviceReady) {
        LogEvent(@{
            @"event":@"background-wake",
            @"result":@"frontboard-unavailable",
            @"scheduleID":[sid description] ?: @"unknown",
            @"bundleID":bundle,
            @"optionsClassFound":@(optionsClass != Nil),
            @"serviceClassFound":@(serviceClass != Nil),
            @"optionsMethodFound":@(optionsReady),
            @"sharedServiceFound":@(serviceReady)
        });
        return;
    }

    id options = nil;
    id service = nil;
    @try {
        NSDictionary *dictionary = @{
            @"__ActivateSuspended": @YES,
            @"__LaunchOrigin": @"BulletinDestinationCoverSheet",
            @"__Actions": @[]
        };
        options = ((id(*)(id,SEL,id))objc_msgSend)(optionsClass,optionsSel,dictionary);
        service = ((id(*)(id,SEL))objc_msgSend)(serviceClass,sharedSel);
    } @catch (NSException *e) {
        LogEvent(@{
            @"event":@"background-wake",
            @"result":@"frontboard-setup-exception",
            @"exception":e.name ?: @"unknown",
            @"scheduleID":[sid description] ?: @"unknown"
        });
        return;
    }

    if (!service || ![service respondsToSelector:openSel]) {
        LogEvent(@{
            @"event":@"background-wake",
            @"result":@"open-method-unavailable",
            @"scheduleID":[sid description] ?: @"unknown",
            @"serviceFound":@(service != nil)
        });
        return;
    }

    LogEvent(@{
        @"event":@"background-wake-request",
        @"scheduleID":[sid description] ?: @"unknown",
        @"bundleID":bundle
    });

    void (^resultBlock)(NSError *) = ^(NSError *error) {
        LogEvent(@{
            @"event":@"background-wake-result",
            @"scheduleID":[sid description] ?: @"unknown",
            @"bundleID":bundle,
            @"result":error ? @"error" : @"success",
            @"errorDomain":error.domain ?: @"",
            @"errorCode":@(error.code)
        });
    };

    @try {
        ((void(*)(id,SEL,id,id,id))objc_msgSend)(service,openSel,bundle,options,resultBlock);
    } @catch (NSException *e) {
        LogEvent(@{
            @"event":@"background-wake",
            @"result":@"open-exception",
            @"exception":e.name ?: @"unknown",
            @"scheduleID":[sid description] ?: @"unknown"
        });
    }
}

static void BackgroundWake(NSString *bundle, id sid) {
    if ([NSThread isMainThread]) {
        BackgroundWakeNow(bundle,sid);
    } else {
        dispatch_sync(dispatch_get_main_queue(), ^{
            BackgroundWakeNow(bundle,sid);
        });
    }
}

static NSString *Key(id sid, NSString *bundle) {
    if (!sid || !bundle.length) return nil;
    return [NSString stringWithFormat:@"%@|%@",bundle,[sid description]];
}

static void Remember(id sid, NSString *bundle) {
    NSString *key = Key(sid,bundle);
    if (!key) return;
    @synchronized(gLock) { gRecent[key] = [NSDate date]; }
}

static BOOL WasRecent(id sid, NSString *bundle) {
    NSString *key = Key(sid,bundle);
    if (!key) return NO;
    @synchronized(gLock) {
        NSDate *now = [NSDate date];
        for (NSString *oldKey in [gRecent.allKeys copy]) {
            NSDate *date = gRecent[oldKey];
            if (!date || [now timeIntervalSinceDate:date] > 12.0) [gRecent removeObjectForKey:oldKey];
        }
        NSDate *date = gRecent[key];
        return date && [now timeIntervalSinceDate:date] <= 12.0;
    }
}

static id FindScheduleID(id object, NSUInteger depth) {
    if (!object || object == [NSNull null] || depth > 5) return nil;
    if ([object isKindOfClass:[NSDictionary class]]) {
        id direct = object[kScheduleKey];
        if (direct && direct != [NSNull null]) return direct;
        for (id value in [object allValues]) {
            id found = FindScheduleID(value,depth+1);
            if (found) return found;
        }
    } else if ([object isKindOfClass:[NSArray class]]) {
        for (id value in object) {
            id found = FindScheduleID(value,depth+1);
            if (found) return found;
        }
    }
    return nil;
}

static id ScheduleIDFromBulletin(id bulletin) {
    id found = FindScheduleID(Value(bulletin,@"userInfo"),0);
    if (found) return found;

    id context = Value(bulletin,@"context");
    Class helper = NSClassFromString(@"WSSchedulerHelper");
    SEL decode = NSSelectorFromString(@"userInfoFromBulletinContext:");
    if (context && helper && [helper respondsToSelector:decode]) {
        @try {
            id userInfo = ((id(*)(id,SEL,id))objc_msgSend)(helper,decode,context);
            found = FindScheduleID(userInfo,0);
        } @catch (__unused NSException *e) {}
    }
    return found;
}

%group ObserveHelper
%hook WSSchedulerHelper
+ (void)sendPushNotificationForScheduleID:(id)sid bundleIdentifier:(NSString *)bundle {
    if (sid && IsWhatsApp(bundle)) {
        Remember(sid,bundle);
        LogEvent(@{@"event":@"helper-forward", @"scheduleID":[sid description], @"bundleID":bundle});
        BackgroundWake(bundle,sid);
    }
    %orig;
}
%end
%end

static void InstallObserver(void) {
    if (gObserverInstalled) return;
    Class helper = NSClassFromString(@"WSSchedulerHelper");
    SEL send = NSSelectorFromString(@"sendPushNotificationForScheduleID:bundleIdentifier:");
    if (helper && [helper respondsToSelector:send]) {
        %init(ObserveHelper);
        gObserverInstalled = YES;
        LogEvent(@{@"event":@"observer-ready"});
    } else {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW,250*NSEC_PER_MSEC),dispatch_get_main_queue(),^{ InstallObserver(); });
    }
}

static void HandleBulletin(id bulletin, NSString *hook) {
    NSString *bundle = BundleForBulletin(bulletin);
    if (!IsWhatsApp(bundle)) return;

    id sid = ScheduleIDFromBulletin(bulletin);
    if (!sid) {
        LogEvent(@{@"event":@"bulletin", @"hook":hook, @"result":@"no-schedule-id", @"bundleID":bundle});
        return;
    }

    if (WasRecent(sid,bundle)) {
        LogEvent(@{@"event":@"bulletin", @"hook":hook, @"result":@"watusi-already-forwarded", @"scheduleID":[sid description]});
        return;
    }

    Class helper = NSClassFromString(@"WSSchedulerHelper");
    SEL send = NSSelectorFromString(@"sendPushNotificationForScheduleID:bundleIdentifier:");
    if (helper && [helper respondsToSelector:send]) {
        @try {
            ((void(*)(id,SEL,id,id))objc_msgSend)(helper,send,sid,bundle);
            LogEvent(@{@"event":@"bulletin", @"hook":hook, @"result":@"fallback-forwarded", @"scheduleID":[sid description]});
            return;
        } @catch (__unused NSException *e) {}
    }

    LogEvent(@{@"event":@"bulletin", @"hook":hook, @"result":@"helper-unavailable", @"scheduleID":[sid description]});
}

%group BulletinHooks
%hook NCBulletinNotificationSource
- (void)observer:(id)observer addBulletin:(id)bulletin forFeed:(unsigned long long)feed {
    %orig;
    HandleBulletin(bulletin,@"short");
}
- (void)observer:(id)observer addBulletin:(id)bulletin forFeed:(unsigned long long)feed playLightsAndSirens:(BOOL)play withReply:(id)reply {
    %orig;
    HandleBulletin(bulletin,@"long");
}
%end
%end

%ctor {
    @autoreleasepool {
        gRecent = [NSMutableDictionary dictionary];
        gLock = [NSObject new];
        %init(BulletinHooks);

        Class bulletinClass = NSClassFromString(@"NCBulletinNotificationSource");
        Class optionsClass = NSClassFromString(@"FBSOpenApplicationOptions");
        Class serviceClass = NSClassFromString(@"FBSSystemService");
        LogEvent(@{
            @"event":@"springboard-loaded",
            @"bulletinClassFound":@(bulletinClass != Nil),
            @"shortMethodFound":@(bulletinClass && [bulletinClass instancesRespondToSelector:NSSelectorFromString(@"observer:addBulletin:forFeed:")]),
            @"longMethodFound":@(bulletinClass && [bulletinClass instancesRespondToSelector:NSSelectorFromString(@"observer:addBulletin:forFeed:playLightsAndSirens:withReply:")]),
            @"frontboardOptionsFound":@(optionsClass != Nil),
            @"frontboardServiceFound":@(serviceClass != Nil)
        });
        dispatch_async(dispatch_get_main_queue(),^{ InstallObserver(); });
    }
}
