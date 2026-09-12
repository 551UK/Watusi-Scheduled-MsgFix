#import <Foundation/Foundation.h>
#import <objc/message.h>
#import <spawn.h>
#import <sys/file.h>
#import <fcntl.h>
#import <unistd.h>
#import "ScheduleStore.h"

extern char **environ;

static NSString * const kDebugPath = @"/var/mobile/Library/Preferences/com.551.watusischeduledmsgfix-debug.plist";
static NSString * const kPendingPath = @"/var/mobile/Library/Preferences/com.551.watusischeduledmsgfix-pending.plist";
static NSString * const kScheduleKey = @"WatusiMessageScheduleID";
static const char *kDebugLockPath = "/var/mobile/Library/Preferences/com.551.watusischeduledmsgfix-debug.lock";
static NSMutableDictionary *gRecent;
static NSObject *gLock;
static BOOL gObserverInstalled = NO;

static void LogEvent(NSDictionary *fields) {
    int fd = open(kDebugLockPath,O_CREAT|O_RDWR,0644);
    if (fd >= 0) flock(fd,LOCK_EX);

    NSDictionary *old = [NSDictionary dictionaryWithContentsOfFile:kDebugPath];
    NSMutableArray *events = [NSMutableArray array];
    if ([old[@"events"] isKindOfClass:[NSArray class]]) [events addObjectsFromArray:old[@"events"]];
    NSMutableDictionary *event = [NSMutableDictionary dictionaryWithDictionary:fields ?: @{}];
    event[@"date"] = [NSDate date];
    event[@"process"] = @"springboard";
    [events addObject:event];
    while (events.count > 80) [events removeObjectAtIndex:0];
    [@{@"version":@"3.1.1",@"date":[NSDate date],@"events":events} writeToFile:kDebugPath atomically:YES];

    if (fd >= 0) { flock(fd,LOCK_UN); close(fd); }
}

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
    if (![[NSFileManager defaultManager] isExecutableFileAtPath:path]) {
        LogEvent(@{@"event":@"shortcuts-helper-spawn",@"result":@"helper-not-found"});
        return;
    }

    pid_t pid = 0;
    const char *tool = path.fileSystemRepresentation;
    char *argv[] = {(char *)tool,NULL};
    int result = posix_spawn(&pid,tool,NULL,NULL,argv,environ);
    LogEvent(@{@"event":@"shortcuts-helper-spawn",@"result":result == 0 ? @"started" : @"failed",@"code":@(result),@"pid":@(pid)});
}

static BOOL QueueShortcutsJob(id sid, NSString *bundle, NSString *sourceTag) {
    if (!sid || !WSMFIsWhatsAppBundle(bundle)) return NO;
    NSString *scheduleID = [sid description];
    if (!scheduleID.length) return NO;

    NSString *storePath = nil;
    NSString *readError = nil;
    id source = WSMFReadScheduleStore(bundle,&storePath,&readError);
    if (!source) {
        LogEvent(@{@"event":@"schedule-store",@"result":@"read-failed",@"source":sourceTag ?: @"unknown",@"bundleID":bundle,@"scheduleID":scheduleID,@"path":storePath ?: @"",@"error":readError ?: @"unknown"});
        return NO;
    }

    NSDictionary *schedule = WSMFFindScheduleDictionary(source,scheduleID,0);
    if (!schedule) {
        LogEvent(@{@"event":@"schedule-store",@"result":@"schedule-not-found",@"source":sourceTag ?: @"unknown",@"bundleID":bundle,@"scheduleID":scheduleID,@"path":storePath ?: @""});
        return NO;
    }

    NSString *message = WSMFScheduleMessage(schedule);
    BOOL groupFound = NO;
    NSString *phone = WSMFSchedulePhone(schedule,&groupFound);
    NSDate *scheduleDate = WSMFScheduleDate(schedule);
    NSString *repeat = WSMFScheduleRepeat(schedule) ?: @"None";

    if (groupFound && !phone.length) {
        LogEvent(@{@"event":@"shortcuts-job",@"result":@"group-not-supported",@"scheduleID":scheduleID});
        return NO;
    }
    if (!message.length || !phone.length) {
        LogEvent(@{@"event":@"shortcuts-job",@"result":@"payload-not-found",@"scheduleID":scheduleID,@"messageFound":@(message.length > 0),@"phoneFound":@(phone.length > 0),@"dateFound":@(scheduleDate != nil),@"repeat":repeat});
        return NO;
    }

    NSString *occurrenceKey = WSMFOccurrenceKey(scheduleID,scheduleDate,phone,message);
    NSMutableDictionary *root = PendingRoot();
    NSMutableDictionary *jobs = root[@"jobs"];
    NSDictionary *existing = jobs[occurrenceKey];
    if ([existing[@"phone"] isKindOfClass:[NSString class]] && [existing[@"message"] isKindOfClass:[NSString class]]) {
        SpawnShortcutsHelper();
        LogEvent(@{@"event":@"shortcuts-job",@"result":@"already-pending",@"scheduleID":scheduleID,@"occurrenceKey":occurrenceKey});
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
    job[@"source"] = sourceTag ?: @"unknown";
    jobs[occurrenceKey] = job;
    root[@"version"] = @"3.1.1";
    root[@"date"] = [NSDate date];

    if (![root writeToFile:kPendingPath atomically:YES]) {
        LogEvent(@{@"event":@"shortcuts-job",@"result":@"pending-write-failed",@"scheduleID":scheduleID});
        return NO;
    }

    LogEvent(@{@"event":@"shortcuts-job",@"result":@"queued",@"source":sourceTag ?: @"unknown",@"scheduleID":scheduleID,@"occurrenceKey":occurrenceKey,@"storePath":storePath ?: @""});
    SpawnShortcutsHelper();
    return YES;
}

%group ObserveHelper
%hook WSSchedulerHelper
+ (void)sendPushNotificationForScheduleID:(id)sid bundleIdentifier:(NSString *)bundle {
    if (sid && WSMFIsWhatsAppBundle(bundle)) {
        LogEvent(@{@"event":@"helper-forward",@"scheduleID":[sid description],@"bundleID":bundle});
        if (QueueShortcutsJob(sid,bundle,@"watusi-helper")) {
            Remember(sid,bundle);
            LogEvent(@{@"event":@"native-watusi",@"result":@"suppressed-for-shortcuts",@"scheduleID":[sid description]});
            return;
        }
        LogEvent(@{@"event":@"native-watusi",@"result":@"queue-failed-pass-through",@"scheduleID":[sid description]});
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
    if (!WSMFIsWhatsAppBundle(bundle)) return;

    id sid = ScheduleIDFromBulletin(bulletin);
    if (!sid) {
        LogEvent(@{@"event":@"bulletin",@"hook":hook,@"result":@"no-schedule-id",@"bundleID":bundle});
        return;
    }
    if (WasRecent(sid,bundle)) {
        LogEvent(@{@"event":@"bulletin",@"hook":hook,@"result":@"already-queued",@"scheduleID":[sid description]});
        return;
    }

    if (QueueShortcutsJob(sid,bundle,[NSString stringWithFormat:@"bulletin-%@",hook])) {
        Remember(sid,bundle);
        return;
    }

    Class helper = NSClassFromString(@"WSSchedulerHelper");
    SEL send = NSSelectorFromString(@"sendPushNotificationForScheduleID:bundleIdentifier:");
    if (helper && [helper respondsToSelector:send]) {
        LogEvent(@{@"event":@"bulletin",@"hook":hook,@"result":@"queue-failed-native-fallback",@"scheduleID":[sid description]});
        @try {
            ((void(*)(id,SEL,id,id))objc_msgSend)(helper,send,sid,bundle);
        } @catch (NSException *e) {
            LogEvent(@{@"event":@"bulletin",@"hook":hook,@"result":@"native-fallback-exception",@"exception":e.name ?: @"unknown"});
        }
    }
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
        NSURL *waContainer = WSMFDataContainerURL(@"net.whatsapp.WhatsApp");
        NSURL *smbContainer = WSMFDataContainerURL(@"net.whatsapp.WhatsAppSMB");
        LogEvent(@{
            @"event":@"springboard-loaded",
            @"bulletinClassFound":@(bulletinClass != Nil),
            @"shortMethodFound":@(bulletinClass && [bulletinClass instancesRespondToSelector:NSSelectorFromString(@"observer:addBulletin:forFeed:")]),
            @"longMethodFound":@(bulletinClass && [bulletinClass instancesRespondToSelector:NSSelectorFromString(@"observer:addBulletin:forFeed:playLightsAndSirens:withReply:")]),
            @"whatsAppContainerFound":@(waContainer != nil),
            @"businessContainerFound":@(smbContainer != nil)
        });
        dispatch_async(dispatch_get_main_queue(),^{ InstallObserver(); });
    }
}
