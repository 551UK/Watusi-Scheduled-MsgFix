#import <Foundation/Foundation.h>
#import <objc/message.h>

static NSString * const DebugPath = @"/var/mobile/Library/Preferences/com.551.watusischeduledmsgfix-debug.plist";
static NSString * const ScheduleKey = @"WatusiMessageScheduleID";
static NSMutableDictionary *recent;
static NSObject *lockObject;
static BOOL observerInstalled = NO;

static id Get(id o, NSString *k) {
    if (!o || !k.length || o == [NSNull null]) return nil;
    @try {
        SEL s = NSSelectorFromString(k);
        if ([o respondsToSelector:s]) return ((id(*)(id,SEL))objc_msgSend)(o,s);
        return [o valueForKey:k];
    } @catch (__unused NSException *e) { return nil; }
}

static BOOL IsWA(NSString *s) {
    return [s isKindOfClass:[NSString class]] && ([s isEqualToString:@"net.whatsapp.WhatsApp"] || [s isEqualToString:@"net.whatsapp.WhatsAppSMB"]);
}

static NSString *BundleID(id o, int depth) {
    if (!o || depth > 4) return nil;
    for (NSString *k in @[@"sectionIdentifier",@"sectionID",@"bundleIdentifier",@"bundleID",@"applicationBundleIdentifier"]) {
        id v=Get(o,k); if ([v isKindOfClass:[NSString class]] && IsWA(v)) return v;
    }
    for (NSString *k in @[@"bulletin",@"bulletinRequest",@"notificationRequest",@"request",@"content"]) {
        id n=Get(o,k); if (n && n!=o) { NSString *v=BundleID(n,depth+1); if (v) return v; }
    }
    return nil;
}

static id FindID(id o, int depth) {
    if (!o || o==[NSNull null] || depth>7) return nil;
    if ([o isKindOfClass:[NSDictionary class]]) {
        id v=o[ScheduleKey]; if (v && v!=[NSNull null]) return v;
        for (NSString *k in @[@"userInfo",@"context",@"content",@"request",@"notification",@"localNotification",@"UNBulletinContextArchivedUserNotification"]) {
            id f=FindID(o[k],depth+1); if (f) return f;
        }
        return nil;
    }
    if ([o isKindOfClass:[NSArray class]]) { for (id v in o) { id f=FindID(v,depth+1); if (f) return f; } return nil; }
    if ([o isKindOfClass:[NSData class]]) {
        @try {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
            id d=[NSKeyedUnarchiver unarchiveObjectWithData:o];
#pragma clang diagnostic pop
            return FindID(d,depth+1);
        } @catch (__unused NSException *e) { return nil; }
    }
    for (NSString *k in @[@"userInfo",@"context",@"content",@"request",@"notification",@"bulletin"]) {
        id n=Get(o,k); if (n && n!=o) { id f=FindID(n,depth+1); if (f) return f; }
    }
    return nil;
}

static id Bulletin(id request) {
    id b=Get(request,@"bulletin"); if (b) return b;
    for (NSString *k in @[@"bulletinRequest",@"notificationRequest",@"request"]) {
        id n=Get(request,k); b=Get(n,@"bulletin"); if (b) return b;
    }
    return nil;
}

static NSString *RequestID(id request) {
    for (NSString *k in @[@"notificationRequestIdentifier",@"requestIdentifier",@"notificationIdentifier",@"identifier",@"recordID",@"bulletinID"]) {
        id v=Get(request,k); if ([v isKindOfClass:[NSString class]] && [v length]) return v;
    }
    return nil;
}

static id ScheduleID(id request) {
    id sid=FindID(request,0); if (sid) return sid;
    id b=Bulletin(request);
    Class h=NSClassFromString(@"WSSchedulerHelper");
    SEL decode=NSSelectorFromString(@"userInfoFromBulletinContext:");
    if (h && [h respondsToSelector:decode]) {
        for (id o in @[b ?: [NSNull null], request ?: [NSNull null]]) {
            if (o==[NSNull null]) continue;
            id c=Get(o,@"context"); if (!c) continue;
            @try { sid=FindID(((id(*)(id,SEL,id))objc_msgSend)(h,decode,c),0); } @catch (__unused NSException *e) {}
            if (sid) return sid;
        }
    }
    NSString *rid=RequestID(request);
    if ([rid hasPrefix:@"schedule-"] && rid.length>9) return [rid substringFromIndex:9];
    return nil;
}

static NSString *Key(id sid, NSString *bundle) { return (sid && bundle.length) ? [NSString stringWithFormat:@"%@|%@",bundle,[sid description]] : nil; }

static void Record(id sid, NSString *bundle) {
    NSString *k=Key(sid,bundle); if (!k) return;
    @synchronized(lockObject) { recent[k]=[NSDate date]; }
}

static BOOL Recent(id sid, NSString *bundle) {
    NSString *k=Key(sid,bundle); if (!k) return NO;
    @synchronized(lockObject) {
        NSDate *now=[NSDate date];
        for (NSString *old in [recent.allKeys copy]) if ([now timeIntervalSinceDate:recent[old]]>8.0) [recent removeObjectForKey:old];
        NSDate *d=recent[k]; return d && [now timeIntervalSinceDate:d]<=8.0;
    }
}

static void Log(NSDictionary *extra) {
    NSMutableDictionary *d=[NSMutableDictionary dictionaryWithDictionary:extra ?: @{}];
    d[@"version"]=@"3.0.0"; d[@"date"]=[NSDate date];
    [d writeToFile:DebugPath atomically:YES];
}

%group ObserveWatusi
%hook WSSchedulerHelper
+ (void)sendPushNotificationForScheduleID:(id)sid bundleIdentifier:(NSString *)bundle {
    if (sid && IsWA(bundle)) Record(sid,bundle);
    %orig;
}
%end
%end

static void InstallObserver(void) {
    if (observerInstalled) return;
    Class h=NSClassFromString(@"WSSchedulerHelper");
    SEL s=NSSelectorFromString(@"sendPushNotificationForScheduleID:bundleIdentifier:");
    if (h && [h respondsToSelector:s]) { %init(ObserveWatusi); observerInstalled=YES; Log(@{@"event":@"observer-ready"}); return; }
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,250*NSEC_PER_MSEC),dispatch_get_main_queue(),^{ InstallObserver(); });
}

static void Bridge(id request, NSString *hook) {
    NSString *bundle=BundleID(request,0); if (!IsWA(bundle)) return;
    id sid=ScheduleID(request); id b=Bulletin(request);
    if (!sid) { Log(@{@"event":@"whatsapp-notification",@"hook":hook,@"result":@"no-schedule-id",@"requestClass":NSStringFromClass([request class]) ?: @"unknown"}); return; }
    if (Recent(sid,bundle)) { Log(@{@"event":@"schedule",@"hook":hook,@"result":@"already-forwarded",@"scheduleID":[sid description]}); return; }
    Class h=NSClassFromString(@"WSSchedulerHelper");
    SEL check=NSSelectorFromString(@"checkBulletin:");
    SEL send=NSSelectorFromString(@"sendPushNotificationForScheduleID:bundleIdentifier:");
    if (b && h && [h respondsToSelector:check]) {
        @try { ((id(*)(id,SEL,id))objc_msgSend)(h,check,b); } @catch (__unused NSException *e) {}
        if (Recent(sid,bundle)) { Log(@{@"event":@"schedule",@"hook":hook,@"result":@"checkBulletin-forwarded",@"scheduleID":[sid description]}); return; }
    }
    if (h && [h respondsToSelector:send]) {
        @try { ((void(*)(id,SEL,id,id))objc_msgSend)(h,send,sid,bundle); Log(@{@"event":@"schedule",@"hook":hook,@"result":@"sendPush-fallback",@"scheduleID":[sid description]}); return; } @catch (__unused NSException *e) {}
    }
    Log(@{@"event":@"schedule",@"hook":hook,@"result":@"helper-failed",@"scheduleID":[sid description],@"helperFound":@(h!=Nil)});
}

%hook CSNotificationDispatcher
- (void)postNotificationRequest:(id)request { %orig; Bridge(request,@"CSNotificationDispatcher"); }
%end

%hook SBDashBoardNotificationDispatcher
- (void)postNotificationRequest:(id)request forCoalescedNotification:(id)coalesced { %orig; Bridge(request,@"SBDashBoardNotificationDispatcher"); }
%end

%ctor {
    @autoreleasepool {
        recent=[NSMutableDictionary dictionary]; lockObject=[NSObject new];
        Log(@{@"event":@"springboard-loaded",@"result":@"native-trigger-bridge-ready"});
        dispatch_async(dispatch_get_main_queue(),^{ InstallObserver(); });
    }
}
