#import <Foundation/Foundation.h>
#import <objc/message.h>
#import <dlfcn.h>
#import <sys/file.h>
#import <sys/stat.h>
#import <fcntl.h>
#import <unistd.h>

static NSString * const kPendingPath = @"/var/mobile/Library/Preferences/com.551.watusischeduledmsgfix-pending.plist";
static NSString * const kDebugPath = @"/var/mobile/Library/Preferences/com.551.watusischeduledmsgfix-debug.plist";
static const char *kDebugLockPath = "/var/mobile/Library/Preferences/com.551.watusischeduledmsgfix-debug.lock";
static const char *kDrainLockPath = "/var/mobile/Library/Preferences/com.551.watusischeduledmsgfix-shortcuts.lock";

static void AppendDebug(NSDictionary *fields) {
    int fd = open(kDebugLockPath, O_CREAT | O_RDWR, 0644);
    if (fd >= 0) flock(fd, LOCK_EX);

    @autoreleasepool {
        NSDictionary *old = [NSDictionary dictionaryWithContentsOfFile:kDebugPath];
        NSMutableArray *events = [NSMutableArray array];
        if ([old[@"events"] isKindOfClass:[NSArray class]]) [events addObjectsFromArray:old[@"events"]];

        NSMutableDictionary *event = [NSMutableDictionary dictionaryWithDictionary:fields ?: @{}];
        event[@"date"] = [NSDate date];
        event[@"process"] = @"shortcuts-helper";
        [events addObject:event];
        while (events.count > 50) [events removeObjectAtIndex:0];

        [@{@"version":@"3.1.0", @"date":[NSDate date], @"events":events} writeToFile:kDebugPath atomically:YES];
    }

    if (fd >= 0) {
        flock(fd, LOCK_UN);
        close(fd);
    }
}

@interface WSMFRunnerDelegate : NSObject
@property (atomic, assign) BOOL done;
@property (atomic, assign) BOOL success;
@property (atomic, assign) BOOL cancelled;
@property (atomic, strong) NSError *error;
@end

@implementation WSMFRunnerDelegate
- (void)workflowRunnerClient:(id)client didStartRunningWorkflowWithProgress:(id)progress {
    (void)client; (void)progress;
}
- (void)workflowRunnerClient:(id)client didFinishRunningWorkflowWithError:(NSError *)error cancelled:(BOOL)cancelled {
    (void)client;
    self.error = error;
    self.cancelled = cancelled;
    self.success = (!error && !cancelled);
    self.done = YES;
}
- (void)workflowRunnerClient:(id)client didFinishRunningWorkflowWithOutput:(id)output error:(NSError *)error cancelled:(BOOL)cancelled {
    (void)client; (void)output;
    self.error = error;
    self.cancelled = cancelled;
    self.success = (!error && !cancelled);
    self.done = YES;
}
@end

static NSString *CleanPhone(NSString *input) {
    if (![input isKindOfClass:[NSString class]]) return nil;
    NSMutableString *digits = [NSMutableString string];
    BOOL hadPlus = [input hasPrefix:@"+"];
    for (NSUInteger i = 0; i < input.length; i++) {
        unichar c = [input characterAtIndex:i];
        if (c >= '0' && c <= '9') [digits appendFormat:@"%C", c];
    }
    if (digits.length < 7 || digits.length > 15) return nil;
    if ([digits hasPrefix:@"00"] && digits.length > 2) {
        [digits deleteCharactersInRange:NSMakeRange(0,2)];
        hadPlus = YES;
    }
    return [NSString stringWithFormat:@"+%@", digits];
}

static NSData *WorkflowData(NSString *phone, NSString *message, NSError **errorOut) {
    NSString *cleanPhone = CleanPhone(phone);
    if (!cleanPhone.length || ![message isKindOfClass:[NSString class]] || !message.length) return nil;

    NSString *vcard = [NSString stringWithFormat:
        @"BEGIN:VCARD\r\n"
         "VERSION:3.0\r\n"
         "PRODID:-//Apple Inc.//iPhone OS 16.2//EN\r\n"
         "N:WhatsApp Recipient;;;;\r\n"
         "FN:WhatsApp Recipient\r\n"
         "TEL;type=CELL;type=VOICE;type=pref:%@\r\n"
         "END:VCARD\r\n", cleanPhone];
    NSData *contactData = [vcard dataUsingEncoding:NSUTF8StringEncoding];

    NSDictionary *contactValue = @{
        @"WFContactData": contactData,
        @"WFContactMultivalue": @0,
        @"WFContactProperty": @3
    };
    NSDictionary *recipients = @{
        @"Value": @{@"WFContactFieldValues": @[contactValue]},
        @"WFSerializationType": @"WFContactFieldValue"
    };
    NSDictionary *intentDefinition = @{
        @"TeamIdentifier": @"57T9237FN3",
        @"BundleIdentifier": @"net.whatsapp.WhatsApp",
        @"Name": @"\u200FWhatsApp",
        @"IntentClassName": @"INSendMessageIntent"
    };
    NSDictionary *parameters = @{
        @"IntentAppDefinition": intentDefinition,
        @"WFSendMessageActionRecipients": recipients,
        @"WFSendMessageContent": message,
        @"ShowWhenRun": @NO,
        @"UUID": [NSUUID UUID].UUIDString
    };
    NSDictionary *action = @{
        @"WFWorkflowActionIdentifier": @"is.workflow.actions.sendmessage",
        @"WFWorkflowActionParameters": parameters
    };
    NSDictionary *workflow = @{
        @"WFWorkflowClientVersion": @"1307.2",
        @"WFWorkflowClientRelease": @"6.0",
        @"WFWorkflowMinimumClientVersion": @900,
        @"WFWorkflowMinimumClientVersionString": @"900",
        @"WFWorkflowTypes": @[],
        @"WFWorkflowInputContentItemClasses": @[],
        @"WFWorkflowIcon": @{
            @"WFWorkflowIconStartColor": @4282601983,
            @"WFWorkflowIconGlyphNumber": @61440
        },
        @"WFWorkflowActions": @[action]
    };

    return [NSPropertyListSerialization dataWithPropertyList:workflow
                                                       format:NSPropertyListBinaryFormat_v1_0
                                                      options:0
                                                        error:errorOut];
}

static BOOL LoadShortcutFrameworks(void) {
    void *workflow = dlopen("/System/Library/PrivateFrameworks/WorkflowKit.framework/WorkflowKit", RTLD_NOW | RTLD_GLOBAL);
    void *voice = dlopen("/System/Library/PrivateFrameworks/VoiceShortcutClient.framework/VoiceShortcutClient", RTLD_NOW | RTLD_GLOBAL);
    return workflow != NULL && voice != NULL;
}

static id Alloc(Class cls) {
    return cls ? ((id(*)(id,SEL))objc_msgSend)((id)cls, sel_registerName("alloc")) : nil;
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

static BOOL RunWhatsAppShortcut(NSString *scheduleID, NSString *phone, NSString *message, NSString **failureText) {
    if (!LoadShortcutFrameworks()) {
        if (failureText) *failureText = @"private-framework-load-failed";
        return NO;
    }

    Class descriptorClass = NSClassFromString(@"WFWorkflowDataRunDescriptor");
    Class requestClass = NSClassFromString(@"WFWorkflowRunRequest");
    Class clientClass = NSClassFromString(@"WFWorkflowRunnerClient");
    if (!descriptorClass || !requestClass || !clientClass) {
        if (failureText) *failureText = @"shortcuts-classes-unavailable";
        return NO;
    }

    NSError *plistError = nil;
    NSData *data = WorkflowData(phone,message,&plistError);
    if (!data) {
        if (failureText) *failureText = plistError.localizedDescription ?: @"workflow-data-failed";
        return NO;
    }

    id descriptorAlloc = Alloc(descriptorClass);
    SEL descriptorInit = sel_registerName("initWithWorkflowData:");
    id descriptor = ((id(*)(id,SEL,id))objc_msgSend)(descriptorAlloc,descriptorInit,data);

    id requestAlloc = Alloc(requestClass);
    SEL requestInit = sel_registerName("initWithInput:presentationMode:");
    id request = ((id(*)(id,SEL,id,unsigned long long))objc_msgSend)(requestAlloc,requestInit,nil,0);
    if (!descriptor || !request) {
        if (failureText) *failureText = @"runner-request-create-failed";
        return NO;
    }

    SetObject(request,"setRunSource:",@"automation");
    SetObject(request,"setAutomationType:",@"PersonalAutomation");
    SetObject(request,"setParentBundleIdentifier:",@"com.apple.shortcuts");
    SetBool(request,"setAllowsDialogNotifications:",NO);
    SetBool(request,"setAllowsHandoff:",NO);
    SetBool(request,"setDonateInteraction:",NO);
    SetBool(request,"setLogRunEvent:",NO);
    SetULL(request,"setOutputBehavior:",0);
    SetULL(request,"setPresentationMode:",0);

    id clientAlloc = Alloc(clientClass);
    SEL clientInit = sel_registerName("initWithDescriptor:runRequest:delegateQueue:");
    id client = ((id(*)(id,SEL,id,id,id))objc_msgSend)(clientAlloc,clientInit,descriptor,request,dispatch_get_main_queue());
    if (!client) {
        if (failureText) *failureText = @"runner-client-create-failed";
        return NO;
    }

    WSMFRunnerDelegate *delegate = [WSMFRunnerDelegate new];
    SetObject(client,"setDelegate:",delegate);

    @try {
        SEL start = sel_registerName("start");
        if (![client respondsToSelector:start]) {
            if (failureText) *failureText = @"runner-start-unavailable";
            return NO;
        }
        ((void(*)(id,SEL))objc_msgSend)(client,start);
    } @catch (NSException *e) {
        if (failureText) *failureText = [NSString stringWithFormat:@"start-exception:%@",e.name ?: @"unknown"];
        return NO;
    }

    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:35.0];
    while (!delegate.done && [deadline timeIntervalSinceNow] > 0) {
        @autoreleasepool {
            CFRunLoopRunInMode(kCFRunLoopDefaultMode,0.20,true);
        }
    }

    if (!delegate.done) {
        SEL stop = sel_registerName("stop");
        if ([client respondsToSelector:stop]) ((void(*)(id,SEL))objc_msgSend)(client,stop);
        if (failureText) *failureText = @"runner-timeout";
        return NO;
    }

    if (!delegate.success) {
        if (failureText) {
            if (delegate.error) *failureText = [NSString stringWithFormat:@"%@:%ld",delegate.error.domain ?: @"error",(long)delegate.error.code];
            else *failureText = delegate.cancelled ? @"runner-cancelled" : @"runner-failed";
        }
        return NO;
    }

    AppendDebug(@{@"event":@"shortcuts-send-success", @"scheduleID":scheduleID ?: @"unknown"});
    return YES;
}

static NSMutableDictionary *MutablePendingRoot(void) {
    NSDictionary *old = [NSDictionary dictionaryWithContentsOfFile:kPendingPath];
    NSMutableDictionary *root = [NSMutableDictionary dictionaryWithDictionary:[old isKindOfClass:[NSDictionary class]] ? old : @{}];
    NSDictionary *jobs = root[@"jobs"];
    root[@"jobs"] = [NSMutableDictionary dictionaryWithDictionary:[jobs isKindOfClass:[NSDictionary class]] ? jobs : @{}];
    return root;
}

static BOOL DrainPending(void) {
    int lockFD = open(kDrainLockPath, O_CREAT | O_RDWR, 0644);
    if (lockFD < 0) return NO;
    if (flock(lockFD, LOCK_EX | LOCK_NB) != 0) {
        close(lockFD);
        return YES;
    }

    NSMutableDictionary *root = MutablePendingRoot();
    NSMutableDictionary *jobs = root[@"jobs"];
    NSArray *scheduleIDs = [jobs.allKeys copy];
    BOOL didWork = NO;

    for (NSString *scheduleID in scheduleIDs) {
        NSMutableDictionary *job = [NSMutableDictionary dictionaryWithDictionary:[jobs[scheduleID] isKindOfClass:[NSDictionary class]] ? jobs[scheduleID] : @{}];
        NSString *phone = job[@"phone"];
        NSString *message = job[@"message"];
        NSDate *nextAttempt = job[@"nextAttempt"];
        if ([nextAttempt isKindOfClass:[NSDate class]] && [nextAttempt timeIntervalSinceNow] > 0) continue;
        if (!CleanPhone(phone).length || ![message isKindOfClass:[NSString class]] || !message.length) {
            AppendDebug(@{@"event":@"shortcuts-job-invalid", @"scheduleID":scheduleID ?: @"unknown"});
            [jobs removeObjectForKey:scheduleID];
            [root writeToFile:kPendingPath atomically:YES];
            continue;
        }

        didWork = YES;
        NSInteger attempts = [job[@"attempts"] integerValue] + 1;
        job[@"attempts"] = @(attempts);
        job[@"lastAttempt"] = [NSDate date];
        job[@"nextAttempt"] = [NSDate dateWithTimeIntervalSinceNow:60.0];
        job[@"state"] = @"sending";
        jobs[scheduleID] = job;
        [root writeToFile:kPendingPath atomically:YES];

        AppendDebug(@{@"event":@"shortcuts-send-attempt", @"scheduleID":scheduleID ?: @"unknown", @"attempt":@(attempts)});
        NSString *failure = nil;
        BOOL success = RunWhatsAppShortcut(scheduleID,phone,message,&failure);

        root = MutablePendingRoot();
        jobs = root[@"jobs"];
        job = [NSMutableDictionary dictionaryWithDictionary:[jobs[scheduleID] isKindOfClass:[NSDictionary class]] ? jobs[scheduleID] : @{}];
        if (success) {
            [jobs removeObjectForKey:scheduleID];
        } else {
            job[@"state"] = @"pending";
            job[@"lastError"] = failure ?: @"unknown";
            job[@"nextAttempt"] = [NSDate dateWithTimeIntervalSinceNow:60.0];
            jobs[scheduleID] = job;
            AppendDebug(@{@"event":@"shortcuts-send-failed", @"scheduleID":scheduleID ?: @"unknown", @"error":failure ?: @"unknown"});
        }
        root[@"date"] = [NSDate date];
        [root writeToFile:kPendingPath atomically:YES];
    }

    flock(lockFD, LOCK_UN);
    close(lockFD);
    return didWork;
}

int main(int argc, char *argv[]) {
    @autoreleasepool {
        (void)argc; (void)argv;
        DrainPending();
    }
    return 0;
}
