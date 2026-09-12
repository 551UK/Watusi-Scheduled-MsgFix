#import <Foundation/Foundation.h>
#import <CoreData/CoreData.h>
#import <UIKit/UIKit.h>
#import <objc/message.h>
#import <objc/runtime.h>
#import "DeliveryPolicy.h"

@protocol WSMFSessionFactory
- (id)newOrExistingChatSessionForJID:(id)jid;
@end

static NSMutableDictionary *ledger;
static NSMutableDictionary *liveMessages;
static NSMutableDictionary *lastRetries;
static BOOL hooksInstalled;
static BOOL ticking;
static unsigned installAttempts;
static NSDate *readyAfter;
static NSString * const nativeContextKey=@"com.551.watusi.native-send-context";
static void Event(NSString *event);
static UIBackgroundTaskIdentifier backgroundTask = UIBackgroundTaskInvalid;

static id Get(id o, NSString *name) {
    @try {
        SEL s = NSSelectorFromString(name);
        if ([o respondsToSelector:s]) return ((id(*)(id,SEL))objc_msgSend)(o,s);
        return [o valueForKey:name];
    } @catch (__unused NSException *e) { return nil; }
}
static id Shared(NSString *name) { return Get(NSClassFromString(name), @"sharedInstance"); }
static NSString *LedgerPath(void) {
    return [NSHomeDirectory() stringByAppendingPathComponent:@"Library/Preferences/com.551.watusischeduledmsgfix-outbox.plist"];
}
static void Load(void) {
    if (ledger) return;
    NSData *d = [NSData dataWithContentsOfFile:LedgerPath()];
    id root = d ? [NSPropertyListSerialization propertyListWithData:d options:NSPropertyListMutableContainers format:nil error:nil] : nil;
    ledger = [root isKindOfClass:[NSMutableDictionary class]] ? root : [NSMutableDictionary dictionary];
    liveMessages = [NSMutableDictionary dictionary];
    lastRetries = [NSMutableDictionary dictionary];
}
static BOOL Save(void) {
    NSData *d = [NSPropertyListSerialization dataWithPropertyList:ledger format:NSPropertyListBinaryFormat_v1_0 options:0 error:nil];
    BOOL ok = d && [d writeToFile:LedgerPath() options:(NSDataWritingAtomic | NSDataWritingFileProtectionNone) error:nil];
    if (ok) [[NSFileManager defaultManager] setAttributes:@{NSFilePosixPermissions:@0600} ofItemAtPath:LedgerPath() error:nil];
    return ok;
}
static void Event(NSString *event) {
    @synchronized ([NSProcessInfo processInfo]) {
        NSString *path=[NSHomeDirectory() stringByAppendingPathComponent:@"Library/Caches/com.551.watusischeduledmsgfix-send.plist"];
        NSDictionary *old=[NSDictionary dictionaryWithContentsOfFile:path];
        NSMutableArray *events=[old[@"events"] isKindOfClass:[NSArray class]] ? [old[@"events"] mutableCopy] : [NSMutableArray array];
        [events addObject:@{@"date":[NSDate date],@"event":event}];
        while (events.count>40) [events removeObjectAtIndex:0];
        [@{@"version":@"1.0.15",@"events":events} writeToFile:path atomically:YES];
    }
}
static NSString *Key(id s) {
    id uid=Get(s,@"uniqueID"), date=Get(s,@"date");
    if (![uid isKindOfClass:[NSString class]] || ![date isKindOfClass:[NSDate class]]) return nil;
    return [NSString stringWithFormat:@"%@|%.3f",uid,[date timeIntervalSince1970]];
}
static BOOL OneOff(id s) {
    id repeat=Get(s,@"repeat");
    return !repeat || [repeat isEqual:@"None"];
}
static NSString *URI(id object) {
    if (![object isKindOfClass:[NSManagedObject class]]) return nil;
    NSManagedObjectID *oid=[object objectID];
    return oid.isTemporaryID ? nil : oid.URIRepresentation.absoluteString;
}
static BOOL BoolCall(id object, NSString *name, id arg) {
    SEL sel=NSSelectorFromString(name);
    return [object respondsToSelector:sel] && ((BOOL(*)(id,SEL,id))objc_msgSend)(object,sel,arg);
}
static id Session(id jid) {
    id wa=Shared(@"FRWhatsApp"); SEL sel=NSSelectorFromString(@"newOrExistingChatSessionForJID:");
    return [wa respondsToSelector:sel] ? [(id<WSMFSessionFactory>)wa newOrExistingChatSessionForJID:jid] : nil;
}
static void KeepAlive(void) {
    if (backgroundTask != UIBackgroundTaskInvalid) return;
    backgroundTask=[[UIApplication sharedApplication] beginBackgroundTaskWithExpirationHandler:^{
        UIBackgroundTaskIdentifier old=backgroundTask; backgroundTask=UIBackgroundTaskInvalid;
        if (old != UIBackgroundTaskInvalid) [[UIApplication sharedApplication] endBackgroundTask:old];
    }];
}
static NSMutableDictionary *Register(id schedule) {
    NSString *key=Key(schedule); if (!key || !OneOff(schedule)) return nil;
    Load();
    NSMutableDictionary *row=ledger[key];
    if (row) return row;
    // Never replay historic schedules whose previous delivery is unknown.
    if ([Get(schedule,@"date") timeIntervalSinceNow] < 0) return nil;
    id recipients=Get(schedule,@"recipients"), message=Get(schedule,@"message");
    if (![recipients isKindOfClass:[NSArray class]] || ![recipients count] || ![message isKindOfClass:[NSString class]] || ![message length]) return nil;
    NSMutableDictionary *states=[NSMutableDictionary dictionary];
    for (id jid in recipients) {
        if (![jid isKindOfClass:[NSString class]]) return nil;
        states[jid]=[NSMutableDictionary dictionaryWithObject:@"ready" forKey:@"state"];
    }
    row=[@{@"id":Get(schedule,@"uniqueID"),@"date":Get(schedule,@"date"),@"status":@"pending",@"recipients":states} mutableCopy];
    ledger[key]=row;
    if (!Save()) { [ledger removeObjectForKey:key]; return nil; }
    return row;
}
static id ResolveMessage(NSString *key, NSString *jid, NSDictionary *state, id session) {
    NSString *token=[key stringByAppendingFormat:@"|%@",jid];
    id live=liveMessages[token]; if (live) return live;
    NSString *uri=state[@"uri"];
    if (![uri isKindOfClass:[NSString class]] || ![session isKindOfClass:[NSManagedObject class]]) return nil;
    NSManagedObjectContext *ctx=[session managedObjectContext];
    NSPersistentStoreCoordinator *psc=ctx.persistentStoreCoordinator;
    for (NSManagedObjectContext *parent=ctx.parentContext; !psc && parent; parent=parent.parentContext) psc=parent.persistentStoreCoordinator;
    NSManagedObjectID *oid=[psc managedObjectIDForURIRepresentation:[NSURL URLWithString:uri]];
    return oid ? [ctx existingObjectWithID:oid error:nil] : nil;
}
static NSString *AttemptPath(void) {
    return [NSHomeDirectory() stringByAppendingPathComponent:@"Library/Caches/com.551.watusischeduledmsgfix-attempt.plist"];
}
static void BeginAttempt(NSString *key, NSString *phase) {
    [@{@"key":key,@"phase":phase,@"date":[NSDate date],@"version":@"1.0.15"}
        writeToFile:AttemptPath() atomically:YES];
}
static void EndAttempt(void) { [[NSFileManager defaultManager] removeItemAtPath:AttemptPath() error:nil]; }
static void RecoverInterruptedAttempt(void) {
    NSDictionary *previous=[NSDictionary dictionaryWithContentsOfFile:AttemptPath()];
    NSString *key=previous[@"key"];
    if (key && ledger[key]) {
        ledger[key][@"blockedByTermination"]=@YES;
        ledger[key][@"interruptedPhase"]=previous[@"phase"] ?: @"unknown";
        Save(); Event(@"interrupted-attempt-kept-pending-without-relaunch-loop");
    }
    EndAttempt();
}
static void Process(id schedule, NSString *key, NSMutableDictionary *row) {
    if ([row[@"status"] isEqual:@"sent"] || [row[@"date"] timeIntervalSinceNow]>0 ||
        [row[@"blockedByTermination"] boolValue] || [readyAfter timeIntervalSinceNow]>0) return;
    id handler=nil;
    BeginAttempt(key,@"resolve-native-handler");
    @try { handler=Shared(@"WSScheduleHandler"); }
    @catch (NSException *e) { row[@"blockedByTermination"]=@YES; Save(); Event([@"handler-exception:" stringByAppendingString:e.name]); }
    @finally { EndAttempt(); }
    if (!handler) return;
    BOOL allReady=YES;
    for (NSDictionary *state in [row[@"recipients"] allValues])
        if (![state[@"state"] isEqual:@"ready"]) allReady=NO;
    if (allReady) {
        // Use the same entry point as a normal Watusi PushKit notification.
        // Do not create sessions or call the text sender from a startup timer.
        SEL native=NSSelectorFromString(@"processScheduleFromPushKitNotificationWithID:");
        if ([handler respondsToSelector:native]) {
            BeginAttempt(key,@"native-schedule-entry");
            @try { ((void(*)(id,SEL,id))objc_msgSend)(handler,native,Get(schedule,@"uniqueID")); }
            @catch (NSException *e) {
                row[@"blockedByTermination"]=@YES; Save(); Event([@"native-exception:" stringByAppendingString:e.name]);
            }
            @finally { EndAttempt(); }
        }
        return;
    }
    BOOL complete=YES;
    for (NSString *jid in row[@"recipients"]) {
        NSMutableDictionary *state=row[@"recipients"][jid];
        if ([state[@"state"] isEqual:@"sent"]) continue;
        complete=NO;
        // Unknown identity is not permission to create another message.
        if (!state[@"uri"]) continue;
        BeginAttempt(key,@"resolve-existing-message");
        @try {
            id session=Session(jid);
            if (![session isKindOfClass:[NSManagedObject class]]) continue;
            NSManagedObjectContext *ctx=[session managedObjectContext];
            [ctx performBlockAndWait:^{
                @try {
                    id message=ResolveMessage(key,jid,state,session);
                    if (!message) return;
                    WSMFAction action=WSMFDeliveryAction(1, message!=nil, BoolCall(handler,@"messageSent:",message));
                    if (action==WSMFConfirm) {
                        state[@"state"]=@"sent";
                        return;
                    }
                    NSString *token=[key stringByAppendingFormat:@"|%@",jid];
                    NSDate *last=lastRetries[token];
                    if (last && -[last timeIntervalSinceNow]<30) return;
                    id storage=Get(Shared(@"FRWhatsApp"),@"chatStorage");
                    SEL retry=NSSelectorFromString(@"retrySendingMessage:");
                    if ([storage respondsToSelector:retry]) {
                        lastRetries[token]=[NSDate date];
                        ((void(*)(id,SEL,id))objc_msgSend)(storage,retry,message);
                    }
                } @catch (NSException *e) { Event([@"message-context-exception:" stringByAppendingString:e.name]); }
            }];
            Save();
        } @catch (NSException *e) {
            row[@"blockedByTermination"]=@YES; Save(); Event([@"resolve-exception:" stringByAppendingString:e.name]);
        } @finally { EndAttempt(); }
    }
    if (complete) { row[@"status"]=@"sent"; Save(); Event(@"all-recipients-confirmed-by-watusi-send-status"); }
}
static void Tick(void) {
    if (ticking) return;
    ticking=YES;
    @try {
        Load();
        id manager=Shared(@"WSSchedulesManager");
        id schedules=Get(manager,@"schedules");
        if (![schedules isKindOfClass:[NSArray class]]) return;
        for (id s in schedules) {
            NSString *key=Key(s); if (!key) continue;
            NSMutableDictionary *row=Register(s);
            if (row) Process(s,key,row);
        }
        // Do not erase durable state while WhatsApp's manager is loading.
        // Explicit save/delete hooks own lifecycle cleanup.
    } @catch (NSException *e) { Event([@"tick-exception:" stringByAppendingString:e.name]); }
    @finally { ticking=NO; }
}
// Capture newly inserted outgoing objects, not a chat's arbitrary last message.
// The observer runs on the saving context's own queue; only immutable identity
// data cross to the main queue. Capture requires the exact session and text.
static void SavedUnchecked(NSNotification *notification) {
    NSMutableArray *candidates=[NSMutableArray array];
    for (NSManagedObject *object in notification.userInfo[NSInsertedObjectsKey]) {
        NSString *uri=URI(object); if (!uri) continue;
        SEL from=NSSelectorFromString(@"isFromMe");
        if (![object respondsToSelector:from] || !((BOOL(*)(id,SEL))objc_msgSend)(object,from)) continue;
        id text=Get(object,@"text");
        NSString *sessionURI=URI(Get(object,@"chatSession"));
        if (![text isKindOfClass:[NSString class]] || !sessionURI) continue;
        [candidates addObject:@{@"uri":uri,@"sessionURI":sessionURI,@"text":text}];
    }
    if (!candidates.count) return;
    dispatch_async(dispatch_get_main_queue(), ^{
        Load();
        id schedules=Get(Shared(@"WSSchedulesManager"),@"schedules");
        if (![schedules isKindOfClass:[NSArray class]]) return;
        for (id s in schedules) {
            NSString *key=Key(s); if (!key) continue;
            NSMutableDictionary *row=ledger[key];
            for (NSString *jid in row[@"recipients"]) {
                NSMutableDictionary *state=row[@"recipients"][jid];
                if (![state[@"state"] isEqual:@"submitted"] || state[@"uri"]) continue;
                NSArray *matches=[candidates filteredArrayUsingPredicate:[NSPredicate predicateWithBlock:^BOOL(NSDictionary *candidate, NSDictionary *bindings) {
                    return [candidate[@"sessionURI"] isEqual:state[@"sessionURI"]] && [candidate[@"text"] isEqual:Get(s,@"message")];
                }]];
                if (matches.count==1) {
                    state[@"uri"]=matches[0][@"uri"];
                    Save(); Event(@"outgoing-message-identity-saved");
                } else if (matches.count>1) Event(@"ambiguous-message-identity-kept-pending");
            }
        }
        Tick();
    });
}
static void Saved(NSNotification *notification) {
    @try { SavedUnchecked(notification); }
    @catch (NSException *e) { Event([@"save-observer-exception:" stringByAppendingString:e.name]); }
}

%group DurableOutbox
%hook WSSchedulesManager
- (void)addOrUpdateSchedule:(id)schedule {
    Load();
    NSString *newKey=Key(schedule);
    id uid=Get(schedule,@"uniqueID");
    for (NSString *oldKey in [ledger.allKeys copy])
        if ([ledger[oldKey][@"id"] isEqual:uid] &&
            (![oldKey isEqual:newKey] || !OneOff(schedule))) [ledger removeObjectForKey:oldKey];
    Save();
    Register(schedule);
    %orig;
}
- (void)removeSchedule:(id)schedule {
    NSString *key=Key(schedule);
    Load();
    if (key) { [ledger removeObjectForKey:key]; Save(); }
    %orig;
}
%end
%hook WSSchedule
- (BOOL)isActive {
    NSString *key=Key(self);
    Load();
    NSDictionary *row=key ? ledger[key] : nil;
    if (row) return ![row[@"status"] isEqual:@"sent"];
    return %orig;
}
%end
%hook WSScheduleHandler
- (void)sendSchedule:(id)schedule retryJIDs:(id)jids timesSent:(NSInteger)times completion:(id)completion {
    NSString *key=Key(schedule);
    Load();
    NSMutableDictionary *row=key ? ledger[key] : nil;
    if (!row) {
        %orig;
        return;
    }
    BOOL allowed=WSMFCanStart(times==0, ![row[@"blockedByTermination"] boolValue], [readyAfter timeIntervalSinceNow]<=0);
    for (NSDictionary *state in [row[@"recipients"] allValues])
        if (![state[@"state"] isEqual:@"ready"]) allowed=NO;
    if (!allowed) {
        if (completion) ((void(^)(void))completion)();
        return;
    }
    for (NSMutableDictionary *state in [row[@"recipients"] allValues]) {
        state[@"state"]=@"submitted";
        state[@"submittedAt"]=[NSDate date];
    }
    if (!Save()) {
        for (NSMutableDictionary *state in [row[@"recipients"] allValues]) state[@"state"]=@"ready";
        if (completion) ((void(^)(void))completion)();
        return;
    }
    NSMutableDictionary *thread=[NSThread currentThread].threadDictionary;
    id previous=thread[nativeContextKey];
    thread[nativeContextKey]=[@{@"key":key,@"recipients":Get(schedule,@"recipients") ?: @[],@"index":@0} mutableCopy];
    KeepAlive();
    BeginAttempt(key,@"original-watusi-first-send");
    @try {
        %orig;
    } @catch (NSException *e) {
        row[@"blockedByTermination"]=@YES; Save(); Event([@"original-send-exception:" stringByAppendingString:e.name]);
        if (completion) ((void(^)(void))completion)();
    } @finally {
        if (previous) thread[nativeContextKey]=previous; else [thread removeObjectForKey:nativeContextKey];
        EndAttempt();
    }
}
%end

%hook FRWhatsApp
- (void)sendMessageWithText:(id)text inChatSession:(id)session {
    // Observe the session Watusi already supplied; never create it ourselves
    // during the first send. The native routine enumerates recipients in order.
    @try {
        NSMutableDictionary *context=[NSThread currentThread].threadDictionary[nativeContextKey];
        NSUInteger index=[context[@"index"] unsignedIntegerValue];
        NSArray *recipients=context[@"recipients"];
        if (context && index<recipients.count) {
            context[@"index"]=@(index+1);
            NSString *uri=URI(session);
            if (uri) {
                ledger[context[@"key"]][@"recipients"][recipients[index]][@"sessionURI"]=uri;
                Save();
            }
        }
    } @catch (NSException *e) { Event([@"session-observer-exception:" stringByAppendingString:e.name]); }
    %orig;
}
%end
%end
static void Install(void) {
    if (hooksInstalled) return;
    Class cls=NSClassFromString(@"WSScheduleHandler");
    Method m=class_getInstanceMethod(cls,NSSelectorFromString(@"sendSchedule:retryJIDs:timesSent:completion:"));
    char type[16]={0}; if (m) method_getArgumentType(m,4,type,sizeof(type));
    if (m && method_getNumberOfArguments(m)==6 && type[0]=='q' && NSClassFromString(@"WSSchedule")) {
        Load();
        readyAfter=[NSDate dateWithTimeIntervalSinceNow:15];
        RecoverInterruptedAttempt();
        %init(DurableOutbox);
        hooksInstalled=YES;
        [[NSNotificationCenter defaultCenter] addObserverForName:NSManagedObjectContextDidSaveNotification object:nil queue:nil usingBlock:^(NSNotification *n){ Saved(n); }];
        [[NSNotificationCenter defaultCenter] addObserverForName:UIApplicationDidBecomeActiveNotification object:nil queue:[NSOperationQueue mainQueue] usingBlock:^(NSNotification *n){ Tick(); }];
        [NSTimer scheduledTimerWithTimeInterval:5 repeats:YES block:^(NSTimer *timer){ Tick(); }];
        Tick(); Event(@"durable-outbox-installed");
    } else if (++installAttempts<120) dispatch_after(dispatch_time(DISPATCH_TIME_NOW,250*NSEC_PER_MSEC),dispatch_get_main_queue(),^{ Install(); });
}
%ctor {
    @autoreleasepool {
        NSString *bundle=[[NSBundle mainBundle] bundleIdentifier];
        if ([bundle isEqualToString:@"net.whatsapp.WhatsApp"] || [bundle isEqualToString:@"net.whatsapp.WhatsAppSMB"])
            dispatch_async(dispatch_get_main_queue(), ^{ Install(); });
    }
}
