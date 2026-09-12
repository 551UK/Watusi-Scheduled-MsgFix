#import <Foundation/Foundation.h>
#import <objc/message.h>
#import <dlfcn.h>
#import <sys/file.h>
#import <fcntl.h>
#import <unistd.h>
#import "ScheduleStore.h"

static NSString * const kPendingPath = @"/var/mobile/Library/Preferences/com.551.watusischeduledmsgfix-pending.plist";
static NSString * const kSentPath = @"/var/mobile/Library/Preferences/com.551.watusischeduledmsgfix-sent.plist";
static NSString * const kInstalledAtPath = @"/var/mobile/Library/Preferences/com.551.watusischeduledmsgfix-installed-at";
static const char *kDrainLockPath = "/var/mobile/Library/Preferences/com.551.watusischeduledmsgfix-shortcuts.lock";

@interface WSMFOOPDelegate : NSObject
@property (atomic, assign) BOOL done;
@property (atomic, assign) BOOL success;
@property (atomic) dispatch_semaphore_t semaphore;
@end

@implementation WSMFOOPDelegate
- (void)outOfProcessWorkflowController:(id)controller didStartFromWorkflowReference:(id)reference {
    (void)controller;
    (void)reference;
}

- (void)outOfProcessWorkflowController:(id)controller didFinishWithResult:(id)result dialogAttribution:(id)dialogAttribution {
    (void)controller;
    (void)dialogAttribution;
    if (self.done) return;

    NSError *error = nil;
    BOOL cancelled = NO;
    @try {
        SEL errorSel = sel_registerName("error");
        if (result && [result respondsToSelector:errorSel]) error = ((id(*)(id,SEL))objc_msgSend)(result,errorSel);
        SEL cancelledSel = sel_registerName("isCancelled");
        if (result && [result respondsToSelector:cancelledSel]) cancelled = ((BOOL(*)(id,SEL))objc_msgSend)(result,cancelledSel);
    } @catch (NSException *e) {
        error = [NSError errorWithDomain:@"com.551.watusischeduledmsgfix" code:12 userInfo:@{NSLocalizedDescriptionKey:e.reason ?: e.name ?: @"result-exception"}];
    }

    self.success = (result != nil && !error && !cancelled);
    self.done = YES;
    if (self.semaphore) dispatch_semaphore_signal(self.semaphore);
}
@end

static NSString *CleanPhone(NSString *input) {
    return WSMFNormalizePhone(input,NULL);
}

static NSData *WorkflowData(NSString *phone, NSString *message) {
    NSString *cleanPhone = CleanPhone(phone);
    if (!cleanPhone.length || ![message isKindOfClass:[NSString class]] || !message.length) return nil;

    NSString *vcard = [NSString stringWithFormat:@"BEGIN:VCARD\r\nVERSION:3.0\r\nPRODID:-//Apple Inc.//iPhone OS 16.2//EN\r\nN:WhatsApp Recipient;;;;\r\nFN:WhatsApp Recipient\r\nTEL;type=CELL;type=VOICE;type=pref:%@\r\nEND:VCARD\r\n",cleanPhone];
    NSData *contactData = [vcard dataUsingEncoding:NSUTF8StringEncoding];
    NSDictionary *contactValue = @{@"WFContactData":contactData,@"WFContactMultivalue":@0,@"WFContactProperty":@3};
    NSDictionary *recipients = @{@"Value":@{@"WFContactFieldValues":@[contactValue]},@"WFSerializationType":@"WFContactFieldValue"};
    NSDictionary *intentDefinition = @{@"TeamIdentifier":@"57T9237FN3",@"BundleIdentifier":@"net.whatsapp.WhatsApp",@"Name":@"\u200FWhatsApp",@"IntentClassName":@"INSendMessageIntent"};
    NSDictionary *parameters = @{@"IntentAppDefinition":intentDefinition,@"WFSendMessageActionRecipients":recipients,@"WFSendMessageContent":message,@"ShowWhenRun":@NO,@"UUID":[NSUUID UUID].UUIDString};
    NSDictionary *action = @{@"WFWorkflowActionIdentifier":@"is.workflow.actions.sendmessage",@"WFWorkflowActionParameters":parameters};
    NSDictionary *workflow = @{@"WFWorkflowClientVersion":@"1307.2",@"WFWorkflowClientRelease":@"6.0",@"WFWorkflowMinimumClientVersion":@900,@"WFWorkflowMinimumClientVersionString":@"900",@"WFWorkflowTypes":@[],@"WFWorkflowInputContentItemClasses":@[],@"WFWorkflowIcon":@{@"WFWorkflowIconStartColor":@4282601983,@"WFWorkflowIconGlyphNumber":@61440},@"WFWorkflowActions":@[action]};

    return [NSPropertyListSerialization dataWithPropertyList:workflow format:NSPropertyListBinaryFormat_v1_0 options:0 error:NULL];
}

static BOOL LoadShortcutFrameworks(void) {
    void *workflow = dlopen("/System/Library/PrivateFrameworks/WorkflowKit.framework/WorkflowKit",RTLD_NOW|RTLD_GLOBAL);
    void *voice = dlopen("/System/Library/PrivateFrameworks/VoiceShortcutClient.framework/VoiceShortcutClient",RTLD_NOW|RTLD_GLOBAL);
    return workflow != NULL && voice != NULL;
}

static id Alloc(Class cls) {
    return cls ? ((id(*)(id,SEL))objc_msgSend)((id)cls,sel_registerName("alloc")) : nil;
}

static void SetObject(id obj, const char *selectorName, id value) {
    SEL sel = sel_registerName(selectorName);
    if (obj && [obj respondsToSelector:sel]) ((void(*)(id,SEL,id))objc_msgSend)(obj,sel,value);
}

static void SetBool(id obj, const char *selectorName, BOOL value) {
    SEL sel = sel_registerName(selectorName);
    if (obj && [obj respondsToSelector:sel]) ((void(*)(id,SEL,BOOL))objc_msgSend)(obj,sel,value);
}

static void SetULL(id obj, const char *selectorName, unsigned long long value) {
    SEL sel = sel_registerName(selectorName);
    if (obj && [obj respondsToSelector:sel]) ((void(*)(id,SEL,unsigned long long))objc_msgSend)(obj,sel,value);
}

static BOOL RunWhatsAppShortcut(NSString *scheduleID, NSString *phone, NSString *message) {
    if (!LoadShortcutFrameworks()) return NO;

    Class descriptorClass = NSClassFromString(@"WFWorkflowDataRunDescriptor");
    Class requestClass = NSClassFromString(@"WFWorkflowRunRequest");
    Class contextClass = NSClassFromString(@"WFWorkflowRunningContext");
    Class controllerClass = NSClassFromString(@"WFOutOfProcessWorkflowController");
    if (!descriptorClass || !requestClass || !contextClass || !controllerClass) return NO;

    NSData *data = WorkflowData(phone,message);
    if (!data) return NO;

    id descriptor = ((id(*)(id,SEL,id))objc_msgSend)(Alloc(descriptorClass),sel_registerName("initWithWorkflowData:"),data);
    id request = ((id(*)(id,SEL,id,unsigned long long))objc_msgSend)(Alloc(requestClass),sel_registerName("initWithInput:presentationMode:"),nil,0);
    NSString *workflowID = [NSString stringWithFormat:@"com.551.watusischeduledmsgfix.%@",scheduleID.length ? scheduleID : [NSUUID UUID].UUIDString];
    id context = ((id(*)(id,SEL,id))objc_msgSend)(Alloc(contextClass),sel_registerName("initWithWorkflowIdentifier:"),workflowID);
    if (!descriptor || !request || !context) return NO;

    SetObject(request,"setRunSource:",@"PersonalAutomation");
    SetObject(request,"setAutomationType:",@"PersonalAutomation");
    SetObject(request,"setParentBundleIdentifier:",@"com.apple.shortcuts");
    SetBool(request,"setAllowsDialogNotifications:",NO);
    SetBool(request,"setAllowsHandoff:",NO);
    SetBool(request,"setDonateInteraction:",NO);
    SetBool(request,"setLogRunEvent:",NO);
    SetULL(request,"setOutputBehavior:",0);
    SetULL(request,"setPresentationMode:",0);

    SetObject(context,"setIdentifier:",workflowID);
    SetObject(context,"setRootWorkflowIdentifier:",workflowID);
    SetObject(context,"setWorkflowIdentifier:",workflowID);
    SetObject(context,"setRunSource:",@"PersonalAutomation");
    SetObject(context,"setAutomationType:",@"PersonalAutomation");
    SetObject(context,"setOriginatingBundleIdentifier:",@"com.apple.shortcuts");
    SetBool(context,"setAllowsDialogNotifications:",NO);
    SetULL(context,"setOutputBehavior:",0);
    SetULL(context,"setPresentationMode:",0);

    id controller = nil;
    @try {
        id allocated = Alloc(controllerClass);
        SEL init4 = sel_registerName("initWithEnvironment:runningContext:databaseProvider:presentationMode:");
        SEL init3 = sel_registerName("initWithEnvironment:runningContext:presentationMode:");
        if ([allocated respondsToSelector:init4]) {
            controller = ((id(*)(id,SEL,long long,id,id,long long))objc_msgSend)(allocated,init4,0,context,nil,0);
        } else if ([allocated respondsToSelector:init3]) {
            controller = ((id(*)(id,SEL,long long,id,long long))objc_msgSend)(allocated,init3,0,context,0);
        }
    } @catch (__unused NSException *e) {
        return NO;
    }
    if (!controller) return NO;

    WSMFOOPDelegate *delegate = [WSMFOOPDelegate new];
    delegate.semaphore = dispatch_semaphore_create(0);
    SetObject(controller,"setDelegate:",delegate);

    BOOL accepted = NO;
    @try {
        SEL runSel = sel_registerName("runWorkflowWithDescriptor:request:error:");
        if (![controller respondsToSelector:runSel]) return NO;
        accepted = ((BOOL(*)(id,SEL,id,id,NSError **))objc_msgSend)(controller,runSel,descriptor,request,NULL);
    } @catch (__unused NSException *e) {
        return NO;
    }
    if (!accepted) return NO;

    long waitResult = dispatch_semaphore_wait(delegate.semaphore,dispatch_time(DISPATCH_TIME_NOW,45*NSEC_PER_SEC));
    if (waitResult != 0 || !delegate.done) {
        SEL stop = sel_registerName("stop");
        if ([controller respondsToSelector:stop]) ((void(*)(id,SEL))objc_msgSend)(controller,stop);
        return NO;
    }

    return delegate.success;
}

static NSMutableDictionary *MutablePendingRoot(void) {
    NSDictionary *old = [NSDictionary dictionaryWithContentsOfFile:kPendingPath];
    NSMutableDictionary *root = [NSMutableDictionary dictionaryWithDictionary:[old isKindOfClass:[NSDictionary class]] ? old : @{}];
    NSDictionary *jobs = root[@"jobs"];
    root[@"jobs"] = [NSMutableDictionary dictionaryWithDictionary:[jobs isKindOfClass:[NSDictionary class]] ? jobs : @{}];
    return root;
}

static NSMutableDictionary *MutableSentRoot(void) {
    NSDictionary *old = [NSDictionary dictionaryWithContentsOfFile:kSentPath];
    NSMutableDictionary *root = [NSMutableDictionary dictionaryWithDictionary:[old isKindOfClass:[NSDictionary class]] ? old : @{}];
    NSDictionary *sent = root[@"sent"];
    root[@"sent"] = [NSMutableDictionary dictionaryWithDictionary:[sent isKindOfClass:[NSDictionary class]] ? sent : @{}];
    return root;
}

static BOOL IsSent(NSString *occurrenceKey) {
    if (!occurrenceKey.length) return NO;
    NSDictionary *root = [NSDictionary dictionaryWithContentsOfFile:kSentPath];
    return [root[@"sent"][occurrenceKey] isKindOfClass:[NSDate class]];
}

static void MarkSent(NSString *occurrenceKey) {
    if (!occurrenceKey.length) return;
    NSMutableDictionary *root = MutableSentRoot();
    NSMutableDictionary *sent = root[@"sent"];
    sent[occurrenceKey] = [NSDate date];

    while (sent.count > 250) {
        NSString *oldestKey = nil;
        NSDate *oldestDate = nil;
        for (NSString *key in sent) {
            NSDate *date = sent[key];
            if (![date isKindOfClass:[NSDate class]]) continue;
            if (!oldestDate || [date compare:oldestDate] == NSOrderedAscending) {
                oldestDate = date;
                oldestKey = key;
            }
        }
        if (!oldestKey) break;
        [sent removeObjectForKey:oldestKey];
    }

    root[@"version"] = @"3.1.4";
    root[@"date"] = [NSDate date];
    [root writeToFile:kSentPath atomically:YES];
}

static NSTimeInterval InstalledAt(void) {
    NSString *text = [NSString stringWithContentsOfFile:kInstalledAtPath encoding:NSUTF8StringEncoding error:NULL];
    NSTimeInterval value = text.doubleValue;
    if (value > 0) return value;
    return [[NSDate date] timeIntervalSince1970] - 300.0;
}

static void ScanDueSchedulesForBundle(NSString *bundle) {
    id source = WSMFReadScheduleStore(bundle,NULL,NULL);
    if (!source) return;

    NSArray *schedules = WSMFAllSchedules(source);
    NSMutableDictionary *pendingRoot = MutablePendingRoot();
    NSMutableDictionary *jobs = pendingRoot[@"jobs"];
    NSDate *now = [NSDate date];
    NSTimeInterval installFloor = InstalledAt() - 300.0;

    for (NSDictionary *schedule in schedules) {
        if (!WSMFRepeatIsNone(schedule)) continue;
        NSDate *date = WSMFScheduleDate(schedule);
        if (!date || [date compare:now] == NSOrderedDescending) continue;
        if (date.timeIntervalSince1970 < installFloor) continue;

        NSString *sid = WSMFScheduleIdentifier(schedule);
        NSString *message = WSMFScheduleMessage(schedule);
        BOOL groupFound = NO;
        NSString *phone = WSMFSchedulePhone(schedule,&groupFound);
        if (!sid.length || !message.length || !phone.length || groupFound) continue;

        NSString *occurrenceKey = WSMFOccurrenceKey(sid,date,phone,message);
        if (IsSent(occurrenceKey) || [jobs[occurrenceKey] isKindOfClass:[NSDictionary class]]) continue;

        jobs[occurrenceKey] = @{
            @"scheduleID":sid,
            @"occurrenceKey":occurrenceKey,
            @"phone":phone,
            @"message":message,
            @"bundleID":bundle,
            @"scheduleDate":date,
            @"repeat":@"None",
            @"created":[NSDate date],
            @"state":@"pending"
        };
    }

    pendingRoot[@"version"] = @"3.1.4";
    pendingRoot[@"date"] = [NSDate date];
    [pendingRoot writeToFile:kPendingPath atomically:YES];
}

static void ScanDueSchedules(void) {
    ScanDueSchedulesForBundle(@"net.whatsapp.WhatsApp");
    ScanDueSchedulesForBundle(@"net.whatsapp.WhatsAppSMB");
}

static void DrainPending(void) {
    int lockFD = open(kDrainLockPath,O_CREAT|O_RDWR,0644);
    if (lockFD < 0) return;
    if (flock(lockFD,LOCK_EX|LOCK_NB) != 0) {
        close(lockFD);
        return;
    }

    ScanDueSchedules();
    NSMutableDictionary *root = MutablePendingRoot();
    NSMutableDictionary *jobs = root[@"jobs"];
    NSArray *occurrenceKeys = [jobs.allKeys copy];

    for (NSString *occurrenceKey in occurrenceKeys) {
        NSMutableDictionary *job = [NSMutableDictionary dictionaryWithDictionary:[jobs[occurrenceKey] isKindOfClass:[NSDictionary class]] ? jobs[occurrenceKey] : @{}];
        NSString *scheduleID = [job[@"scheduleID"] description] ?: @"unknown";
        NSString *phone = job[@"phone"];
        NSString *message = job[@"message"];
        NSDate *nextAttempt = job[@"nextAttempt"];

        if (IsSent(occurrenceKey)) {
            [jobs removeObjectForKey:occurrenceKey];
            [root writeToFile:kPendingPath atomically:YES];
            continue;
        }
        if ([nextAttempt isKindOfClass:[NSDate class]] && [nextAttempt timeIntervalSinceNow] > 0) continue;
        if (!CleanPhone(phone).length || ![message isKindOfClass:[NSString class]] || !message.length) {
            [jobs removeObjectForKey:occurrenceKey];
            [root writeToFile:kPendingPath atomically:YES];
            continue;
        }

        job[@"nextAttempt"] = [NSDate dateWithTimeIntervalSinceNow:60.0];
        job[@"state"] = @"sending";
        jobs[occurrenceKey] = job;
        [root writeToFile:kPendingPath atomically:YES];

        BOOL success = RunWhatsAppShortcut(scheduleID,phone,message);

        root = MutablePendingRoot();
        jobs = root[@"jobs"];
        job = [NSMutableDictionary dictionaryWithDictionary:[jobs[occurrenceKey] isKindOfClass:[NSDictionary class]] ? jobs[occurrenceKey] : @{}];

        if (success) {
            MarkSent(occurrenceKey);
            [jobs removeObjectForKey:occurrenceKey];
        } else {
            job[@"state"] = @"pending";
            job[@"nextAttempt"] = [NSDate dateWithTimeIntervalSinceNow:60.0];
            jobs[occurrenceKey] = job;
        }

        root[@"version"] = @"3.1.4";
        root[@"date"] = [NSDate date];
        [root writeToFile:kPendingPath atomically:YES];
    }

    flock(lockFD,LOCK_UN);
    close(lockFD);
}

int main(int argc, char *argv[]) {
    @autoreleasepool {
        (void)argc;
        (void)argv;
        DrainPending();
    }
    return 0;
}
