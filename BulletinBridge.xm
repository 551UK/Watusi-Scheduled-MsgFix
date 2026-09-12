#import <Foundation/Foundation.h>
#import <objc/message.h>
#import <spawn.h>
#import <sys/file.h>
#import <fcntl.h>
#import <unistd.h>

extern char **environ;

static NSString * const kDebug = @"/var/mobile/Library/Preferences/com.551.watusischeduledmsgfix-debug.plist";
static NSString * const kPending = @"/var/mobile/Library/Preferences/com.551.watusischeduledmsgfix-pending.plist";
static NSString * const kMirror = @"/var/mobile/Library/Preferences/com.551.watusischeduledmsgfix-schedule-mirror.plist";
static NSString * const kScheduleKey = @"WatusiMessageScheduleID";
static const char *kDebugLockPath = "/var/mobile/Library/Preferences/com.551.watusischeduledmsgfix-debug.lock";
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
    int fd = open(kDebugLockPath, O_CREAT | O_RDWR, 0644);
    if (fd >= 0) flock(fd, LOCK_EX);

    NSDictionary *old = [NSDictionary dictionaryWithContentsOfFile:kDebug];
    NSMutableArray *events = [NSMutableArray array];
    if ([old[@"events"] isKindOfClass:[NSArray class]]) [events addObjectsFromArray:old[@"events"]];
    NSMutableDictionary *event = [NSMutableDictionary dictionaryWithDictionary:fields ?: @{}];
    event[@"date"] = [NSDate date];
    event[@"process"] = @"springboard";
    [events addObject:event];
    while (events.count > 50) [events removeObjectAtIndex:0];
    [@{@"version":@"3.1.0", @"date":[NSDate date], @"events":events} writeToFile:kDebug atomically:YES];

    if (fd >= 0) { flock(fd, LOCK_UN); close(fd); }
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

static BOOL SameID(id value, NSString *sid) {
    if (!value || !sid.length) return NO;
    return [[[value description] lowercaseString] isEqualToString:[sid lowercaseString]];
}

static NSDictionary *FindScheduleDictionary(id obj, NSString *sid, NSUInteger depth) {
    if (!obj || obj == [NSNull null] || depth > 14) return nil;
    if ([obj isKindOfClass:[NSDictionary class]]) {
        NSDictionary *dict = obj;
        for (NSString *key in dict) {
            if ([[key description] isEqualToString:sid] && [dict[key] isKindOfClass:[NSDictionary class]]) return dict[key];
        }
        for (NSString *key in @[@"identifier",@"scheduleID",@"scheduleId",@"id",@"uuid",@"UUID"]) {
            if (SameID(dict[key],sid)) return dict;
        }
        for (id value in dict.allValues) {
            NSDictionary *found = FindScheduleDictionary(value,sid,depth+1);
            if (found) return found;
        }
    } else if ([obj isKindOfClass:[NSArray class]]) {
        for (id value in (NSArray *)obj) {
            NSDictionary *found = FindScheduleDictionary(value,sid,depth+1);
            if (found) return found;
        }
    }
    return nil;
}

static NSString *FirstStringForKeys(NSDictionary *dict, NSArray<NSString *> *keys, NSUInteger depth) {
    if (![dict isKindOfClass:[NSDictionary class]] || depth > 8) return nil;
    for (NSString *wanted in keys) {
        for (id rawKey in dict) {
            NSString *key = [[rawKey description] lowercaseString];
            if (![key isEqualToString:[wanted lowercaseString]]) continue;
            id value = dict[rawKey];
            if ([value isKindOfClass:[NSString class]] && [value length]) return value;
            if ([value isKindOfClass:[NSDictionary class]]) {
                NSString *nested = FirstStringForKeys(value,keys,depth+1);
                if (nested.length) return nested;
            }
        }
    }
    return nil;
}

static NSString *NormalizedPhoneFromString(NSString *value, BOOL *groupFound) {
    if (![value isKindOfClass:[NSString class]] || !value.length) return nil;
    NSString *lower = value.lowercaseString;
    if ([lower containsString:@"@g.us"]) {
        if (groupFound) *groupFound = YES;
        return nil;
    }

    NSString *candidate = value;
    NSRange at = [candidate rangeOfString:@"@"];
    if (at.location != NSNotFound) candidate = [candidate substringToIndex:at.location];

    NSMutableString *digits = [NSMutableString string];
    for (NSUInteger i = 0; i < candidate.length; i++) {
        unichar c = [candidate characterAtIndex:i];
        if (c >= '0' && c <= '9') [digits appendFormat:@"%C",c];
    }
    if (digits.length < 7 || digits.length > 15) return nil;
    if ([digits hasPrefix:@"00"] && digits.length > 2) [digits deleteCharactersInRange:NSMakeRange(0,2)];
    return [NSString stringWithFormat:@"+%@",digits];
}

static NSString *FindPhone(id obj, NSUInteger depth, BOOL *groupFound) {
    if (!obj || obj == [NSNull null] || depth > 10) return nil;
    if ([obj isKindOfClass:[NSString class]]) return NormalizedPhoneFromString(obj,groupFound);
    if ([obj isKindOfClass:[NSArray class]] || [obj isKindOfClass:[NSSet class]]) {
        NSArray *array = [obj isKindOfClass:[NSSet class]] ? [obj allObjects] : obj;
        for (id value in array) {
            NSString *phone = FindPhone(value,depth+1,groupFound);
            if (phone.length) return phone;
        }
        return nil;
    }
    if ([obj isKindOfClass:[NSDictionary class]]) {
        NSDictionary *dict = obj;
        NSArray *priority = @[@"jid",@"userjid",@"chatjid",@"phone",@"phonenumber",@"number",@"identifier",@"user"];
        for (NSString *wanted in priority) {
            for (id rawKey in dict) {
                if (![[[rawKey description] lowercaseString] isEqualToString:wanted]) continue;
                NSString *phone = FindPhone(dict[rawKey],depth+1,groupFound);
                if (phone.length) return phone;
            }
        }
        for (id value in dict.allValues) {
            NSString *phone = FindPhone(value,depth+1,groupFound);
            if (phone.length) return phone;
        }
    }
    return nil;
}

static id ScheduleSource(void) {
    NSDictionary *mirror = [NSDictionary dictionaryWithContentsOfFile:kMirror];
    if ([mirror[@"raw"] isKindOfClass:[NSArray class]] || [mirror[@"raw"] isKindOfClass:[NSDictionary class]]) return mirror[@"raw"];

    NSArray *paths = @[
        @"/var/mobile/Library/Preferences/com.fouadraheb.watusi.scheduled-messages.plist",
        @"/var/jb/var/mobile/Library/Preferences/com.fouadraheb.watusi.scheduled-messages.plist"
    ];
    for (NSString *path in paths) {
        id obj = [NSDictionary dictionaryWithContentsOfFile:path];
        if (!obj) obj = [NSArray arrayWithContentsOfFile:path];
        if (obj) return obj;
    }
    return nil;
}

static NSMutableDictionary *PendingRoot(void) {
    NSDictionary *old = [NSDictionary dictionaryWithContentsOfFile:kPending];
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

static BOOL QueueShortcutsJob(id sid, NSString *bundle) {
    if (!sid || !IsWhatsApp(bundle)) return NO;
    NSString *scheduleID = [sid description];
    if (!scheduleID.length) return NO;

    NSMutableDictionary *root = PendingRoot();
    NSMutableDictionary *jobs = root[@"jobs"];
    NSDictionary *existing = jobs[scheduleID];
    if ([existing[@"phone"] isKindOfClass:[NSString class]] && [existing[@"message"] isKindOfClass:[NSString class]]) {
        SpawnShortcutsHelper();
        LogEvent(@{@"event":@"shortcuts-job",@"result":@"already-pending",@"scheduleID":scheduleID});
        return YES;
    }

    id source = ScheduleSource();
    NSDictionary *schedule = FindScheduleDictionary(source,scheduleID,0);
    if (!schedule) {
        LogEvent(@{@"event":@"shortcuts-job",@"result":@"schedule-not-found",@"scheduleID":scheduleID,@"mirrorFound":@([[NSFileManager defaultManager] fileExistsAtPath:kMirror])});
        return NO;
    }

    NSString *message = FirstStringForKeys(schedule,@[@"messageText",@"message",@"text",@"content"],0);
    id recipients = nil;
    for (NSString *wanted in @[@"recipientsSelected",@"recipients",@"recipient",@"to"]) {
        for (id rawKey in schedule) {
            if ([[[rawKey description] lowercaseString] isEqualToString:[wanted lowercaseString]]) {
                recipients = schedule[rawKey];
                break;
            }
        }
        if (recipients) break;
    }
    BOOL groupFound = NO;
    NSString *phone = FindPhone(recipients ?: schedule,0,&groupFound);

    if (groupFound && !phone.length) {
        LogEvent(@{@"event":@"shortcuts-job",@"result":@"group-not-supported",@"scheduleID":scheduleID});
        return NO;
    }
    if (!message.length || !phone.length) {
        LogEvent(@{@"event":@"shortcuts-job",@"result":@"payload-not-found",@"scheduleID":scheduleID,@"messageFound":@(message.length > 0),@"phoneFound":@(phone.length > 0)});
        return NO;
    }

    NSMutableDictionary *job = [NSMutableDictionary dictionary];
    job[@"phone"] = phone;
    job[@"message"] = message;
    job[@"bundleID"] = bundle;
    job[@"created"] = [NSDate date];
    job[@"state"] = @"pending";
    job[@"attempts"] = @0;
    jobs[scheduleID] = job;
    root[@"version"] = @"3.1.0";
    root[@"date"] = [NSDate date];

    if (![root writeToFile:kPending atomically:YES]) {
        LogEvent(@{@"event":@"shortcuts-job",@"result":@"pending-write-failed",@"scheduleID":scheduleID});
        return NO;
    }

    LogEvent(@{@"event":@"shortcuts-job",@"result":@"queued",@"scheduleID":scheduleID});
    SpawnShortcutsHelper();
    return YES;
}

%group ObserveHelper
%hook WSSchedulerHelper
+ (void)sendPushNotificationForScheduleID:(id)sid bundleIdentifier:(NSString *)bundle {
    if (sid && IsWhatsApp(bundle)) {
        Remember(sid,bundle);
        LogEvent(@{@"event":@"helper-forward", @"scheduleID":[sid description], @"bundleID":bundle});
        if (QueueShortcutsJob(sid,bundle)) {
            LogEvent(@{@"event":@"native-watusi",@"result":@"suppressed-for-shortcuts",@"scheduleID":[sid description]});
            return;
        }
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
            LogEvent(@{@"event":@"bulletin", @"hook":hook, @"result":@"forwarded-to-handler", @"scheduleID":[sid description]});
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
        LogEvent(@{
            @"event":@"springboard-loaded",
            @"bulletinClassFound":@(bulletinClass != Nil),
            @"shortMethodFound":@(bulletinClass && [bulletinClass instancesRespondToSelector:NSSelectorFromString(@"observer:addBulletin:forFeed:")]),
            @"longMethodFound":@(bulletinClass && [bulletinClass instancesRespondToSelector:NSSelectorFromString(@"observer:addBulletin:forFeed:playLightsAndSirens:withReply:")]),
            @"shortcutsEngine":@YES
        });
        dispatch_async(dispatch_get_main_queue(),^{ InstallObserver(); });
    }
}
