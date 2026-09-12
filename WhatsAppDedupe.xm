#import <Foundation/Foundation.h>
#import <objc/runtime.h>

// Deduplicate the first SEND, not the wake-up or schedule lookup. Watusi's
// timesSent > 0 calls retry an existing message and must pass through.
@interface WSMFSendEntry : NSObject
@property(nonatomic, strong) NSDate *started;
@property(nonatomic, strong) NSMutableArray *completions;
@property(nonatomic) BOOL finished;
@end
@implementation WSMFSendEntry
@end
static NSMutableDictionary *gSends;
static BOOL gInstalled;
static unsigned gInstallAttempts;

static void LogSend(NSString *event) {
    NSString *path = [NSHomeDirectory() stringByAppendingPathComponent:@"Library/Caches/com.551.watusischeduledmsgfix-send.plist"];
    [@{@"version":@"1.0.14", @"date":[NSDate date], @"event":event}
        writeToFile:path atomically:YES];
}

static NSString *SendKey(id schedule) {
    @try {
        id identifier = [schedule valueForKey:@"uniqueID"];
        id date = [schedule valueForKey:@"date"];
        if (![identifier isKindOfClass:[NSString class]] || ![identifier length] ||
            ![date isKindOfClass:[NSDate class]]) return nil;
        return [NSString stringWithFormat:@"%@|%.3f", identifier, [date timeIntervalSince1970]];
    } @catch (__unused NSException *e) { return nil; }
}

%group SendGuard
%hook WSScheduleHandler
- (void)sendSchedule:(id)schedule retryJIDs:(id)jids timesSent:(NSInteger)times completion:(id)completion {
    NSString *key = times == 0 ? SendKey(schedule) : nil;
    if (!key) { %orig; return; }
    __block WSMFSendEntry *entry;
    BOOL duplicate = NO;
    BOOL finished = NO;
    @synchronized ([WSMFSendEntry class]) {
        if (!gSends) gSends = [NSMutableDictionary dictionary];
        NSDate *now = [NSDate date];
        for (NSString *oldKey in [gSends.allKeys copy]) {
            WSMFSendEntry *old = gSends[oldKey];
            if ([now timeIntervalSinceDate:old.started] > 10.0) [gSends removeObjectForKey:oldKey];
        }
        entry = gSends[key];
        duplicate = entry != nil;
        if (!entry) {
            entry = [WSMFSendEntry new];
            entry.started = now;
            entry.completions = [NSMutableArray array];
            gSends[key] = entry;
        }
        finished = entry.finished;
        if (completion && !finished) [entry.completions addObject:[completion copy]];
    }
    if (duplicate) {
        LogSend(@"duplicate-first-send-joined");
        if (completion && finished) ((void (^)(void))completion)();
        return;
    }
    LogSend(@"first-send-entered-delivery-unconfirmed");
    void (^done)(void) = ^{
        NSArray *callbacks;
        @synchronized ([WSMFSendEntry class]) {
            if (entry.finished) return;
            entry.finished = YES;
            callbacks = [entry.completions copy];
            [entry.completions removeAllObjects];
        }
        // Watusi's completion also runs after retry exhaustion, so this is
        // deliberately not recorded as a delivery receipt.
        LogSend(@"send-routine-completed-delivery-unconfirmed");
        for (id callback in callbacks) ((void (^)(void))callback)();
    };
    @try { %orig(schedule, jids, times, done); }
    @catch (NSException *exception) {
        @synchronized ([WSMFSendEntry class]) {
            if (gSends[key] == entry) [gSends removeObjectForKey:key];
        }
        @throw exception;
    }
}
%end
%end

static void InstallSendGuard(void) {
    if (gInstalled) return;
    Class cls = NSClassFromString(@"WSScheduleHandler");
    Method m = class_getInstanceMethod(cls, NSSelectorFromString(@"sendSchedule:retryJIDs:timesSent:completion:"));
    if (m) {
        char result[16] = {0}, count[16] = {0};
        method_getReturnType(m, result, sizeof(result));
        method_getArgumentType(m, 4, count, sizeof(count));
        if (method_getNumberOfArguments(m) != 6 || result[0] != 'v' || count[0] != 'q') {
            LogSend(@"unsupported-send-signature");
            return;
        }
        %init(SendGuard);
        gInstalled = YES;
        LogSend(@"send-guard-installed");
    } else if (++gInstallAttempts < 120) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 250*NSEC_PER_MSEC),
            dispatch_get_main_queue(), ^{ InstallSendGuard(); });
    } else LogSend(@"watusi-handler-unavailable");
}
%ctor {
    @autoreleasepool {
        NSString *bundle = [[NSBundle mainBundle] bundleIdentifier];
        if ([bundle isEqualToString:@"net.whatsapp.WhatsApp"] || [bundle isEqualToString:@"net.whatsapp.WhatsAppSMB"])
            dispatch_async(dispatch_get_main_queue(), ^{ InstallSendGuard(); });
    }
}
