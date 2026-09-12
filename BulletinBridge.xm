#import <Foundation/Foundation.h>
#import <objc/message.h>
#import <spawn.h>
#import "ScheduleStore.h"

extern char **environ;

static NSString * const kPendingPath = @"/var/mobile/Library/Preferences/com.551.watusischeduledmsgfix-pending.plist";
static NSString * const kScheduleKey = @"WatusiMessageScheduleID";
static NSMutableDictionary *gRecent;
static NSObject *gLock;
static BOOL gObserverInstalled = NO;

static NSString *BundleForBulletin(id bulletin) {
    for (NSString *key in @[@"sectionID",@"sectionIdentifier",@"bundleIdentifier"]) {
        id value = WSMFValue(bulletin,key);
        if ([value isKindOfClass:[NSString class]] && WSMFIsWhatsAppBundle(value)) return value;
    }
    return nil;
}

static id FindScheduleID(id object, NSUInteger depth) {
    if (!object || object == [NSNull null] || depth > 7) return nil;
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
    id found = FindScheduleID(WSMFValue(bulletin,@"userInfo"),0);
    if (found) return found;

    id context = WSMFValue(bulletin,@"context");
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

static NSString *RecentKey(id sid, NSString *bundle) {
    if (!sid || !bundle.length) return nil;
    return [NSString stringWithFormat:@"%@|%@",bundle,[sid description]];
}

static void Remember(id sid, NSString *bundle) {
    NSString *key = RecentKey(sid,bundle);
    if (!key) return;
    @synchronized(gLock) { gRecent[key] = [NSDate date]; }
}

static BOOL WasRecent(id sid, NSString *bundle) {
    NSString *key = RecentKey(sid,bundle);
    if (!key) return NO;
    @synchronized(gLock) {
        NSDate *now = [NSDate date];
        for (NSString *oldKey in [gRecent.allKeys copy]) {
            NSDate *date = gRecent[oldKey];
            if (!date || [now timeIntervalSinceDate:date] > 20.0) [gRecent removeObjectForKey:oldKey];
        }
        NSDate *date = gRecent[key];
        return date && [now timeIntervalSinceDate:date] <= 20.0;
    }
}

static NSMutableDictionary *PendingRoot(void) {
    NSDictionary *old = [NSDictionary dictionaryWithContentsOfFile:kPendingPath];
    NSMutableDictionary *root = [NSMutableDictionary dictionaryWithDictionary:[old isKindOfClass:[NSDictionary class]] ? old : @{}];
    NSDictionary *jobs = root[@"jobs"];
    root[@"jobs"] = [NSMutableDictionary dictionaryWithDictionary:[jobs isKindOfClass:[NSDictionary class]] ? jobs : @{}];
    return root;
}

static void SpawnShortcutsHelper(void) {
    NSString *path = @"/var/jb/usr/bin/WatusiShortcutSend";
    if (![[NSFileManager defaultManager] isExecutableFileAtPath:path]) path = @"/usr/bin/WatusiShortcutSend";
    if (![[NSFileManager defaultManager] isExecutableFileAtPath:path]) return;

    pid_t pid = 0;
    const char *tool = path.fileSystemRepresentation;
    char *argv[] = {(char *)tool,NULL};
    posix_spawn(&pid,tool,NULL,NULL,argv,environ);
}

static BOOL QueueShortcutsJob(id sid, NSString *bundle) {
    if (!sid || !WSMFIsWhatsAppBundle(bundle)) return NO;
    NSString *scheduleID = [sid description];
    if (!scheduleID.length) return NO;

    id source = WSMFReadScheduleStore(bundle,NULL,NULL);
    if (!source) return NO;

    NSDictionary *schedule = WSMFFindScheduleDictionary(source,scheduleID,0);
    if (!schedule) return NO;

    NSString *message = WSMFScheduleMessage(schedule);
    BOOL groupFound = NO;
    NSString *phone = WSMFSchedulePhone(schedule,&groupFound);
    NSDate *scheduleDate = WSMFScheduleDate(schedule);
    NSString *repeat = WSMFScheduleRepeat(schedule) ?: @"None";

    if (groupFound || !message.length || !phone.length) return NO;

    NSString *occurrenceKey = WSMFOccurrenceKey(scheduleID,scheduleDate,phone,message);
    NSMutableDictionary *root = PendingRoot();
    NSMutableDictionary *jobs = root[@"jobs"];
    NSDictionary *existing = jobs[occurrenceKey];
    if ([existing[@"phone"] isKindOfClass:[NSString class]] && [existing[@"message"] isKindOfClass:[NSString class]]) {
        SpawnShortcutsHelper();
        return YES;
    }

    NSMutableDictionary *job = [NSMutableDictionary dictionary];
    job[@"scheduleID"] = scheduleID;
    job[@"occurrenceKey"] = occurrenceKey;
    job[@"phone"] = phone;
    job[@"message"] = message;
    job[@"bundleID"] = bundle;
    if (scheduleDate) job[@"scheduleDate"] = scheduleDate;
    job[@"repeat"] = repeat;
    job[@"created"] = [NSDate date];
    job[@"state"] = @"pending";
    job[@"attempts"] = @0;
    jobs[occurrenceKey] = job;
    root[@"version"] = @"3.1.4";
    root[@"date"] = [NSDate date];

    if (![root writeToFile:kPendingPath atomically:YES]) return NO;
    SpawnShortcutsHelper();
    return YES;
}

%group ObserveHelper
%hook WSSchedulerHelper
+ (void)sendPushNotificationForScheduleID:(id)sid bundleIdentifier:(NSString *)bundle {
    if (sid && WSMFIsWhatsAppBundle(bundle) && QueueShortcutsJob(sid,bundle)) {
        Remember(sid,bundle);
        return;
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
    } else {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW,250*NSEC_PER_MSEC),dispatch_get_main_queue(),^{ InstallObserver(); });
    }
}

static void HandleBulletin(id bulletin) {
    NSString *bundle = BundleForBulletin(bulletin);
    if (!WSMFIsWhatsAppBundle(bundle)) return;

    id sid = ScheduleIDFromBulletin(bulletin);
    if (!sid || WasRecent(sid,bundle)) return;

    if (QueueShortcutsJob(sid,bundle)) {
        Remember(sid,bundle);
        return;
    }

    Class helper = NSClassFromString(@"WSSchedulerHelper");
    SEL send = NSSelectorFromString(@"sendPushNotificationForScheduleID:bundleIdentifier:");
    if (helper && [helper respondsToSelector:send]) {
        @try {
            ((void(*)(id,SEL,id,id))objc_msgSend)(helper,send,sid,bundle);
        } @catch (__unused NSException *e) {}
    }
}

%group BulletinHooks
%hook NCBulletinNotificationSource
- (void)observer:(id)observer addBulletin:(id)bulletin forFeed:(unsigned long long)feed {
    %orig;
    HandleBulletin(bulletin);
}
- (void)observer:(id)observer addBulletin:(id)bulletin forFeed:(unsigned long long)feed playLightsAndSirens:(BOOL)play withReply:(id)reply {
    %orig;
    HandleBulletin(bulletin);
}
%end
%end

%ctor {
    @autoreleasepool {
        gRecent = [NSMutableDictionary dictionary];
        gLock = [NSObject new];
        %init(BulletinHooks);
        dispatch_async(dispatch_get_main_queue(),^{ InstallObserver(); });
    }
}
