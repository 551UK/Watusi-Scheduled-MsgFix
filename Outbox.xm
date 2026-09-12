#import <Foundation/Foundation.h>
#import <CoreData/CoreData.h>
#import <UIKit/UIKit.h>
#import <objc/message.h>
#import <objc/runtime.h>
#import "DeliveryPolicy.h"

static NSMutableDictionary *ledger;
static NSMutableDictionary *liveMessages;
static NSMutableDictionary *lastRetries;
static BOOL hooksInstalled;
static BOOL ticking;
static unsigned installAttempts;
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
    [@{@"version":@"1.0.14", @"date":[NSDate date], @"event":event}
        writeToFile:[NSHomeDirectory() stringByAppendingPathComponent:@"Library/Caches/com.551.watusischeduledmsgfix-send.plist"] atomically:YES];
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
    return [wa respondsToSelector:sel] ? ((id(*)(id,SEL,id))objc_msgSend)(wa,sel,jid) : nil;
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
static void Process(id schedule, NSString *key, NSMutableDictionary *row) {
    if ([row[@"status"] isEqual:@"sent"] || [row[@"date"] timeIntervalSinceNow]>0) return;
    id wa=Shared(@"FRWhatsApp"), handler=Shared(@"WSScheduleHandler");
    id storage=Get(wa,@"chatStorage");
    if (!storage || !handler) return;
    BOOL complete=YES;
    for (NSString *jid in row[@"recipients"]) {
        NSMutableDictionary *state=row[@"recipients"][jid];
        if ([state[@"state"] isEqual:@"sent"]) continue;
        id session=Session(jid); if (!session) { complete=NO; continue; }
        id message=ResolveMessage(key,jid,state,session);
        BOOL sent=message && BoolCall(handler,@"messageSent:",message);
        WSMFAction action=WSMFDeliveryAction(![state[@"state"] isEqual:@"ready"], message!=nil, sent);
        if (action==WSMFConfirm) {
            state[@"state"]=@"sent";
            Save();
            continue;
        }
        complete=NO;
        KeepAlive();
        NSString *token=[key stringByAppendingFormat:@"|%@",jid];
        if (action==WSMFRetry) {
            NSString *uri=URI(message);
            if (uri && !state[@"uri"]) { state[@"uri"]=uri; Save(); }
            NSDate *last=lastRetries[token];
            if (last && -[last timeIntervalSinceNow]<30) continue;
            SEL retry=NSSelectorFromString(@"retrySendingMessage:");
            if ([storage respondsToSelector:retry]) {
                lastRetries[token]=[NSDate date];
                ((void(*)(id,SEL,id))objc_msgSend)(storage,retry,message);
            }
        } else if (action==WSMFCreate) {
            SEL send=NSSelectorFromString(@"sendMessageWithText:inChatSession:");
            NSString *sessionURI=URI(session);
            if (![wa respondsToSelector:send] || !sessionURI) continue;
            // Wait for the application's sending backend to be ready.
            NSArray *selectors=@[@"sendMessageWithText:attachments:messageOrigin:toChatSessions:hasTextFromURL:",
                @"sendMessageWithText:metadata:messageOrigin:toChatSessions:hasTextFromURL:",
                @"sendMessageWithText:metadata:toChatSessions:hasTextFromURL:",
                @"sendMessageWithText:metadata:multicast:replyingToItem:inChatSession:",
                @"sendMessageWithText:metadata:replyingToItem:inChatSession:"];
            BOOL backendReady=NO;
            for (NSString *name in selectors)
                if ([storage respondsToSelector:NSSelectorFromString(name)] ||
                    [Get(wa,@"messageSender") respondsToSelector:NSSelectorFromString(name)]) backendReady=YES;
            if (!backendReady) continue;
            // Serialize identity capture for scheduled sends to the same chat.
            BOOL busy=NO;
            for (NSDictionary *otherRow in ledger.allValues)
                for (NSDictionary *other in [otherRow[@"recipients"] allValues])
                    if ([other[@"state"] isEqual:@"submitted"] && !other[@"uri"] &&
                        [other[@"sessionURI"] isEqual:sessionURI]) busy=YES;
            if (busy) continue;
            // Persist intent BEFORE calling an asynchronous sending API.
            state[@"state"]=@"submitted";
            state[@"sessionURI"]=sessionURI;
            state[@"submittedAt"]=[NSDate date];
            if (!Save()) { state[@"state"]=@"ready"; continue; }
            ((void(*)(id,SEL,id,id))objc_msgSend)(wa,send,Get(schedule,@"message"),session);
            Event(@"message-submitted-awaiting-identity-and-status");
        }
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
    } @finally { ticking=NO; }
}
// Capture newly inserted outgoing objects, not a chat's arbitrary last message.
// The observer runs on the saving context's own queue; only immutable identity
// data cross to the main queue. Capture requires the exact session and text.
static void Saved(NSNotification *notification) {
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
    if (key && ledger[key]) {
        // Native completion only releases its background task. Our ledger owns
        // pending/sent state, and our retry path uses the captured message ID.
        dispatch_async(dispatch_get_main_queue(), ^{ Tick(); if (completion) ((void(^)(void))completion)(); });
        return;
    }
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
