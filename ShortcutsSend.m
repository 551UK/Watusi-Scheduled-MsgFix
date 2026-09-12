#import <Foundation/Foundation.h>
#import <objc/message.h>
#import <dlfcn.h>
#import <sys/file.h>
#import <sys/stat.h>
#import <fcntl.h>
#import <unistd.h>
#import "ScheduleStore.h"

static NSString * const kPendingPath = @"/var/mobile/Library/Preferences/com.551.watusischeduledmsgfix-pending.plist";
static NSString * const kSentPath = @"/var/mobile/Library/Preferences/com.551.watusischeduledmsgfix-sent.plist";
static NSString * const kDebugPath = @"/var/mobile/Library/Preferences/com.551.watusischeduledmsgfix-debug.plist";
static NSString * const kInstalledAtPath = @"/var/mobile/Library/Preferences/com.551.watusischeduledmsgfix-installed-at";
static const char *kDebugLockPath = "/var/mobile/Library/Preferences/com.551.watusischeduledmsgfix-debug.lock";
static const char *kDrainLockPath = "/var/mobile/Library/Preferences/com.551.watusischeduledmsgfix-shortcuts.lock";

static void AppendDebug(NSDictionary *fields) {
    int fd = open(kDebugLockPath,O_CREAT|O_RDWR,0644);
    if (fd >= 0) flock(fd,LOCK_EX);
    @autoreleasepool {
        NSDictionary *old = [NSDictionary dictionaryWithContentsOfFile:kDebugPath];
        NSMutableArray *events = [NSMutableArray array];
        if ([old[@"events"] isKindOfClass:[NSArray class]]) [events addObjectsFromArray:old[@"events"]];
        NSMutableDictionary *event = [NSMutableDictionary dictionaryWithDictionary:fields ?: @{}];
        event[@"date"] = [NSDate date];
        event[@"process"] = @"shortcuts-helper";
        [events addObject:event];
        while (events.count > 100) [events removeObjectAtIndex:0];
        [@{@"version":@"3.1.2",@"date":[NSDate date],@"events":events} writeToFile:kDebugPath atomically:YES];
    }
    if (fd >= 0) { flock(fd,LOCK_UN); close(fd); }
}

@interface WSMFOOPDelegate : NSObject
@property (atomic, assign) BOOL done;
@property (atomic, assign) BOOL success;
@property (atomic, assign) BOOL cancelled;
@property (atomic, assign) BOOL hadResult;
@property (atomic, strong) NSError *error;
@property (atomic) dispatch_semaphore_t semaphore;
@property (atomic, copy) NSString *scheduleID;
@end

@implementation WSMFOOPDelegate
- (void)outOfProcessWorkflowController:(id)controller didStartFromWorkflowReference:(id)reference {
    (void)controller; (void)reference;
    AppendDebug(@{@"event":@"oop-runner-callback",@"result":@"started",@"scheduleID":self.scheduleID ?: @"unknown"});
}
- (void)outOfProcessWorkflowController:(id)controller didFinishWithResult:(id)result dialogAttribution:(id)dialogAttribution {
    (void)controller; (void)dialogAttribution;
    if (self.done) return;
    self.hadResult = (result != nil);
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
    self.error = error;
    self.cancelled = cancelled;
    self.success = (result != nil && !error && !cancelled);
    self.done = YES;
    AppendDebug(@{@"event":@"oop-runner-callback",
                  @"result":self.success ? @"finished-success" : (cancelled ? @"cancelled" : @"finished-error"),
                  @"scheduleID":self.scheduleID ?: @"unknown",
                  @"hadResult":@(result != nil),
                  @"errorDomain":error.domain ?: @"",
                  @"errorCode":@(error.code),
                  @"errorDescription":error.localizedDescription ?: @""});
    if (self.semaphore) dispatch_semaphore_signal(self.semaphore);
}
@end

static NSString *CleanPhone(NSString *input) { return WSMFNormalizePhone(input,NULL); }

static NSData *WorkflowData(NSString *phone, NSString *message, NSError **errorOut) {
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
    return [NSPropertyListSerialization dataWithPropertyList:workflow format:NSPropertyListBinaryFormat_v1_0 options:0 error:errorOut];
}

static BOOL LoadShortcutFrameworks(void) {
    void *workflow = dlopen("/System/Library/PrivateFrameworks/WorkflowKit.framework/WorkflowKit",RTLD_NOW|RTLD_GLOBAL);
    void *voice = dlopen("/System/Library/PrivateFrameworks/VoiceShortcutClient.framework/VoiceShortcutClient",RTLD_NOW|RTLD_GLOBAL);
    AppendDebug(@{@"event":@"shortcuts-frameworks",@"workflowKit":@(workflow != NULL),@"voiceShortcutClient":@(voice != NULL)});
    return workflow != NULL && voice != NULL;
}

static id Alloc(Class cls) { return cls ? ((id(*)(id,SEL))objc_msgSend)((id)cls,sel_registerName("alloc")) : nil; }
static void SetObject(id obj, const char *selectorName, id value) { SEL sel = sel_registerName(selectorName); if (obj && [obj respondsToSelector:sel]) ((void(*)(id,SEL,id))objc_msgSend)(obj,sel,value); }
static void SetBool(id obj, const char *selectorName, BOOL value) { SEL sel = sel_registerName(selectorName); if (obj && [obj respondsToSelector:sel]) ((void(*)(id,SEL,BOOL))objc_msgSend)(obj,sel,value); }
static void SetULL(id obj, const char *selectorName, unsigned long long value) { SEL sel = sel_registerName(selectorName); if (obj && [obj respondsToSelector:sel]) ((void(*)(id,SEL,unsigned long long))objc_msgSend)(obj,sel,value); }

static BOOL RunWhatsAppShortcut(NSString *scheduleID, NSString *phone, NSString *message, NSString **failureText) {
    AppendDebug(@{@"event":@"oop-runner",@"result":@"begin",@"scheduleID":scheduleID ?: @"unknown"});
    if (!LoadShortcutFrameworks()) { if (failureText) *failureText = @"private-framework-load-failed"; return NO; }

    Class descriptorClass = NSClassFromString(@"WFWorkflowDataRunDescriptor");
    Class requestClass = NSClassFromString(@"WFWorkflowRunRequest");
    Class contextClass = NSClassFromString(@"WFWorkflowRunningContext");
    Class controllerClass = NSClassFromString(@"WFOutOfProcessWorkflowController");
    AppendDebug(@{@"event":@"oop-classes",
                  @"descriptor":@(descriptorClass != Nil),
                  @"request":@(requestClass != Nil),
                  @"context":@(contextClass != Nil),
                  @"controller":@(controllerClass != Nil)});
    if (!descriptorClass || !requestClass || !contextClass || !controllerClass) {
        if (failureText) *failureText = @"oop-classes-unavailable";
        return NO;
    }

    NSError *plistError = nil;
    NSData *data = WorkflowData(phone,message,&plistError);
    if (!data) { if (failureText) *failureText = plistError.localizedDescription ?: @"workflow-data-failed"; return NO; }

    id descriptor = ((id(*)(id,SEL,id))objc_msgSend)(Alloc(descriptorClass),sel_registerName("initWithWorkflowData:"),data);
    id request = ((id(*)(id,SEL,id,unsigned long long))objc_msgSend)(Alloc(requestClass),sel_registerName("initWithInput:presentationMode:"),nil,0);
    NSString *workflowID = [NSString stringWithFormat:@"com.551.watusischeduledmsgfix.%@",scheduleID.length ? scheduleID : [NSUUID UUID].UUIDString];
    id context = ((id(*)(id,SEL,id))objc_msgSend)(Alloc(contextClass),sel_registerName("initWithWorkflowIdentifier:"),workflowID);
    if (!descriptor || !request || !context) {
        if (failureText) *failureText = @"oop-request-create-failed";
        return NO;
    }

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
            AppendDebug(@{@"event":@"oop-controller",@"result":@"init4",@"scheduleID":scheduleID ?: @"unknown"});
        } else if ([allocated respondsToSelector:init3]) {
            controller = ((id(*)(id,SEL,long long,id,long long))objc_msgSend)(allocated,init3,0,context,0);
            AppendDebug(@{@"event":@"oop-controller",@"result":@"init3",@"scheduleID":scheduleID ?: @"unknown"});
        }
    } @catch (NSException *e) {
        if (failureText) *failureText = [NSString stringWithFormat:@"oop-init-exception:%@",e.name ?: @"unknown"];
        AppendDebug(@{@"event":@"oop-controller",@"result":@"init-exception",@"exception":e.name ?: @"unknown",@"reason":e.reason ?: @""});
        return NO;
    }
    if (!controller) { if (failureText) *failureText = @"oop-controller-create-failed"; return NO; }

    WSMFOOPDelegate *delegate = [WSMFOOPDelegate new];
    delegate.scheduleID = scheduleID;
    delegate.semaphore = dispatch_semaphore_create(0);
    SetObject(controller,"setDelegate:",delegate);

    NSError *startError = nil;
    BOOL accepted = NO;
    @try {
        SEL runSel = sel_registerName("runWorkflowWithDescriptor:request:error:");
        if (![controller respondsToSelector:runSel]) {
            if (failureText) *failureText = @"oop-run-selector-unavailable";
            return NO;
        }
        accepted = ((BOOL(*)(id,SEL,id,id,NSError **))objc_msgSend)(controller,runSel,descriptor,request,&startError);
        AppendDebug(@{@"event":@"oop-start",
                      @"accepted":@(accepted),
                      @"scheduleID":scheduleID ?: @"unknown",
                      @"errorDomain":startError.domain ?: @"",
                      @"errorCode":@(startError.code),
                      @"errorDescription":startError.localizedDescription ?: @""});
    } @catch (NSException *e) {
        if (failureText) *failureText = [NSString stringWithFormat:@"oop-start-exception:%@",e.name ?: @"unknown"];
        AppendDebug(@{@"event":@"oop-start",@"accepted":@NO,@"exception":e.name ?: @"unknown",@"reason":e.reason ?: @""});
        return NO;
    }
    if (!accepted) {
        if (failureText) {
            if (startError) *failureText = [NSString stringWithFormat:@"%@:%ld",startError.domain ?: @"error",(long)startError.code];
            else *failureText = @"oop-start-rejected";
        }
        return NO;
    }

    long waitResult = dispatch_semaphore_wait(delegate.semaphore,dispatch_time(DISPATCH_TIME_NOW,45*NSEC_PER_SEC));
    if (waitResult != 0 || !delegate.done) {
        SEL stop = sel_registerName("stop");
        if ([controller respondsToSelector:stop]) ((void(*)(id,SEL))objc_msgSend)(controller,stop);
        if (failureText) *failureText = @"oop-runner-timeout";
        AppendDebug(@{@"event":@"oop-runner",@"result":@"timeout",@"scheduleID":scheduleID ?: @"unknown"});
        return NO;
    }
    if (!delegate.success) {
        if (failureText) {
            if (delegate.error) *failureText = [NSString stringWithFormat:@"%@:%ld",delegate.error.domain ?: @"error",(long)delegate.error.code];
            else *failureText = delegate.cancelled ? @"oop-runner-cancelled" : (delegate.hadResult ? @"oop-runner-failed" : @"oop-runner-no-result");
        }
        return NO;
    }

    AppendDebug(@{@"event":@"shortcuts-send-success",@"scheduleID":scheduleID ?: @"unknown",@"route":@"background-runner-xpc"});
    return YES;
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
            if (!oldestDate || [date compare:oldestDate] == NSOrderedAscending) { oldestDate = date; oldestKey = key; }
        }
        if (!oldestKey) break;
        [sent removeObjectForKey:oldestKey];
    }
    root[@"version"] = @"3.1.2";
    root[@"date"] = [NSDate date];
    [root writeToFile:kSentPath atomically:YES];
}

static NSTimeInterval InstalledAt(void) {
    NSString *text = [NSString stringWithContentsOfFile:kInstalledAtPath encoding:NSUTF8StringEncoding error:NULL];
    NSTimeInterval value = text.doubleValue;
    if (value > 0) return value;
    return [[NSDate date] timeIntervalSince1970] - 300.0;
}

static NSUInteger ScanDueSchedulesForBundle(NSString *bundle) {
    NSString *storePath = nil;
    NSString *readError = nil;
    id source = WSMFReadScheduleStore(bundle,&storePath,&readError);
    if (!source) {
        AppendDebug(@{@"event":@"schedule-scan",@"bundleID":bundle,@"result":@"store-unavailable",@"path":storePath ?: @"",@"error":readError ?: @"unknown"});
        return 0;
    }
    NSArray *schedules = WSMFAllSchedules(source);
    NSMutableDictionary *pendingRoot = MutablePendingRoot();
    NSMutableDictionary *jobs = pendingRoot[@"jobs"];
    NSDate *now = [NSDate date];
    NSTimeInterval installFloor = InstalledAt() - 300.0;
    NSUInteger queued = 0;
    NSUInteger dueSeen = 0;
    for (NSDictionary *schedule in schedules) {
        if (!WSMFRepeatIsNone(schedule)) continue;
        NSDate *date = WSMFScheduleDate(schedule);
        if (!date || [date compare:now] == NSOrderedDescending) continue;
        if (date.timeIntervalSince1970 < installFloor) continue;
        dueSeen++;
        NSString *sid = WSMFScheduleIdentifier(schedule);
        NSString *message = WSMFScheduleMessage(schedule);
        BOOL groupFound = NO;
        NSString *phone = WSMFSchedulePhone(schedule,&groupFound);
        if (!sid.length || !message.length || !phone.length || groupFound) {
            AppendDebug(@{@"event":@"schedule-scan",@"result":@"due-payload-invalid",@"bundleID":bundle,@"scheduleID":sid ?: @"unknown",@"messageFound":@(message.length > 0),@"phoneFound":@(phone.length > 0),@"group":@(groupFound)});
            continue;
        }
        NSString *occurrenceKey = WSMFOccurrenceKey(sid,date,phone,message);
        if (IsSent(occurrenceKey) || [jobs[occurrenceKey] isKindOfClass:[NSDictionary class]]) continue;
        jobs[occurrenceKey] = @{@"scheduleID":sid,@"occurrenceKey":occurrenceKey,@"phone":phone,@"message":message,@"bundleID":bundle,@"scheduleDate":date,@"repeat":@"None",@"created":[NSDate date],@"state":@"pending",@"attempts":@0,@"source":@"store-scanner"};
        queued++;
    }
    pendingRoot[@"version"] = @"3.1.2";
    pendingRoot[@"date"] = [NSDate date];
    [pendingRoot writeToFile:kPendingPath atomically:YES];
    AppendDebug(@{@"event":@"schedule-scan",@"bundleID":bundle,@"result":@"ok",@"storePath":storePath ?: @"",@"scheduleCount":@(schedules.count),@"dueSeen":@(dueSeen),@"queued":@(queued)});
    return queued;
}

static void ScanDueSchedules(void) {
    ScanDueSchedulesForBundle(@"net.whatsapp.WhatsApp");
    ScanDueSchedulesForBundle(@"net.whatsapp.WhatsAppSMB");
}

static BOOL DrainPending(void) {
    int lockFD = open(kDrainLockPath,O_CREAT|O_RDWR,0644);
    if (lockFD < 0) return NO;
    if (flock(lockFD,LOCK_EX|LOCK_NB) != 0) { close(lockFD); return YES; }
    ScanDueSchedules();
    NSMutableDictionary *root = MutablePendingRoot();
    NSMutableDictionary *jobs = root[@"jobs"];
    NSArray *occurrenceKeys = [jobs.allKeys copy];
    BOOL didWork = NO;
    for (NSString *occurrenceKey in occurrenceKeys) {
        NSMutableDictionary *job = [NSMutableDictionary dictionaryWithDictionary:[jobs[occurrenceKey] isKindOfClass:[NSDictionary class]] ? jobs[occurrenceKey] : @{}];
        NSString *scheduleID = [job[@"scheduleID"] description] ?: @"unknown";
        NSString *phone = job[@"phone"];
        NSString *message = job[@"message"];
        NSDate *nextAttempt = job[@"nextAttempt"];
        if (IsSent(occurrenceKey)) { [jobs removeObjectForKey:occurrenceKey]; [root writeToFile:kPendingPath atomically:YES]; continue; }
        if ([nextAttempt isKindOfClass:[NSDate class]] && [nextAttempt timeIntervalSinceNow] > 0) continue;
        if (!CleanPhone(phone).length || ![message isKindOfClass:[NSString class]] || !message.length) {
            AppendDebug(@{@"event":@"shortcuts-job-invalid",@"scheduleID":scheduleID,@"occurrenceKey":occurrenceKey});
            [jobs removeObjectForKey:occurrenceKey];
            [root writeToFile:kPendingPath atomically:YES];
            continue;
        }
        didWork = YES;
        NSInteger attempts = [job[@"attempts"] integerValue] + 1;
        job[@"attempts"] = @(attempts);
        job[@"lastAttempt"] = [NSDate date];
        job[@"nextAttempt"] = [NSDate dateWithTimeIntervalSinceNow:60.0];
        job[@"state"] = @"sending";
        jobs[occurrenceKey] = job;
        [root writeToFile:kPendingPath atomically:YES];
        AppendDebug(@{@"event":@"shortcuts-send-attempt",@"scheduleID":scheduleID,@"occurrenceKey":occurrenceKey,@"attempt":@(attempts),@"source":job[@"source"] ?: @"unknown"});
        NSString *failure = nil;
        BOOL success = RunWhatsAppShortcut(scheduleID,phone,message,&failure);
        root = MutablePendingRoot();
        jobs = root[@"jobs"];
        job = [NSMutableDictionary dictionaryWithDictionary:[jobs[occurrenceKey] isKindOfClass:[NSDictionary class]] ? jobs[occurrenceKey] : @{}];
        if (success) { MarkSent(occurrenceKey); [jobs removeObjectForKey:occurrenceKey]; }
        else {
            job[@"state"] = @"pending";
            job[@"lastError"] = failure ?: @"unknown";
            job[@"nextAttempt"] = [NSDate dateWithTimeIntervalSinceNow:60.0];
            jobs[occurrenceKey] = job;
            AppendDebug(@{@"event":@"shortcuts-send-failed",@"scheduleID":scheduleID,@"occurrenceKey":occurrenceKey,@"error":failure ?: @"unknown"});
        }
        root[@"version"] = @"3.1.2";
        root[@"date"] = [NSDate date];
        [root writeToFile:kPendingPath atomically:YES];
    }
    flock(lockFD,LOCK_UN);
    close(lockFD);
    return didWork;
}

int main(int argc, char *argv[]) {
    @autoreleasepool {
        (void)argc; (void)argv;
        AppendDebug(@{@"event":@"shortcuts-helper-start",@"pid":@((int)getpid()),@"uid":@((int)getuid()),@"euid":@((int)geteuid()),@"route":@"background-runner-xpc"});
        DrainPending();
        AppendDebug(@{@"event":@"shortcuts-helper-exit"});
    }
    return 0;
}
