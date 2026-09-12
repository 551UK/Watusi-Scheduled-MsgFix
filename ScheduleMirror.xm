#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <substrate.h>
#import <sys/file.h>
#import <fcntl.h>
#import <unistd.h>

static NSString * const kMirrorPath = @"/var/mobile/Library/Preferences/com.551.watusischeduledmsgfix-schedule-mirror.plist";
static NSString * const kDebugPath = @"/var/mobile/Library/Preferences/com.551.watusischeduledmsgfix-debug.plist";
static const char *kDebugLockPath = "/var/mobile/Library/Preferences/com.551.watusischeduledmsgfix-debug.lock";
static BOOL gInstalled = NO;
static void (*gOrigInstanceSave)(id,SEL,id) = NULL;
static void (*gOrigClassSave)(id,SEL,id) = NULL;

static void AppendDebug(NSDictionary *fields) {
    int fd = open(kDebugLockPath, O_CREAT | O_RDWR, 0644);
    if (fd >= 0) flock(fd, LOCK_EX);
    NSDictionary *old = [NSDictionary dictionaryWithContentsOfFile:kDebugPath];
    NSMutableArray *events = [NSMutableArray array];
    if ([old[@"events"] isKindOfClass:[NSArray class]]) [events addObjectsFromArray:old[@"events"]];
    NSMutableDictionary *event = [NSMutableDictionary dictionaryWithDictionary:fields ?: @{}];
    event[@"date"] = [NSDate date];
    event[@"process"] = @"whatsapp";
    [events addObject:event];
    while (events.count > 50) [events removeObjectAtIndex:0];
    [@{@"version":@"3.1.0", @"date":[NSDate date], @"events":events} writeToFile:kDebugPath atomically:YES];
    if (fd >= 0) { flock(fd, LOCK_UN); close(fd); }
}

static id PlistSafe(id obj, NSUInteger depth) {
    if (!obj || obj == [NSNull null] || depth > 12) return nil;
    if ([obj isKindOfClass:[NSString class]] || [obj isKindOfClass:[NSNumber class]] ||
        [obj isKindOfClass:[NSDate class]] || [obj isKindOfClass:[NSData class]]) return obj;
    if ([obj isKindOfClass:[NSArray class]]) {
        NSMutableArray *out = [NSMutableArray array];
        for (id value in (NSArray *)obj) {
            id safe = PlistSafe(value,depth+1);
            if (safe) [out addObject:safe];
        }
        return out;
    }
    if ([obj isKindOfClass:[NSSet class]]) return PlistSafe([(NSSet *)obj allObjects],depth+1);
    if ([obj isKindOfClass:[NSDictionary class]]) {
        NSMutableDictionary *out = [NSMutableDictionary dictionary];
        [(NSDictionary *)obj enumerateKeysAndObjectsUsingBlock:^(id key, id value, BOOL *stop) {
            (void)stop;
            NSString *safeKey = [key isKindOfClass:[NSString class]] ? key : [key description];
            id safe = PlistSafe(value,depth+1);
            if (safeKey.length && safe) out[safeKey] = safe;
        }];
        return out;
    }

    NSMutableDictionary *out = [NSMutableDictionary dictionary];
    for (NSString *key in @[@"identifier",@"message",@"messageText",@"recipients",@"recipientsSelected",@"repeat",@"date",@"nextTriggerDate",@"active"]) {
        @try {
            id value = [obj valueForKey:key];
            id safe = PlistSafe(value,depth+1);
            if (safe) out[key] = safe;
        } @catch (__unused NSException *e) {}
    }
    return out.count ? out : [obj description];
}

static void Mirror(id raw) {
    @autoreleasepool {
        id safe = PlistSafe(raw,0);
        if (!safe) {
            AppendDebug(@{@"event":@"schedule-mirror", @"result":@"empty"});
            return;
        }
        NSDictionary *wrapper = @{@"version":@"3.1.0", @"date":[NSDate date], @"raw":safe};
        BOOL ok = [wrapper writeToFile:kMirrorPath atomically:YES];
        AppendDebug(@{@"event":@"schedule-mirror", @"result":ok ? @"saved" : @"write-failed"});
    }
}

static void HookInstanceSave(id self, SEL _cmd, id raw) {
    Mirror(raw);
    if (gOrigInstanceSave) gOrigInstanceSave(self,_cmd,raw);
}

static void HookClassSave(id self, SEL _cmd, id raw) {
    Mirror(raw);
    if (gOrigClassSave) gOrigClassSave(self,_cmd,raw);
}

static void InstallHooks(void) {
    if (gInstalled) return;
    Class cls = objc_getClass("WSSchedulesSaver");
    if (!cls) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW,500*NSEC_PER_MSEC),dispatch_get_main_queue(),^{ InstallHooks(); });
        return;
    }

    SEL sel = NSSelectorFromString(@"saveRawSchedules:");
    Method instanceMethod = class_getInstanceMethod(cls,sel);
    Method classMethod = class_getClassMethod(cls,sel);
    BOOL hooked = NO;
    if (instanceMethod) {
        MSHookMessageEx(cls,sel,(IMP)HookInstanceSave,(IMP *)&gOrigInstanceSave);
        hooked = YES;
    }
    if (classMethod) {
        Class meta = object_getClass(cls);
        MSHookMessageEx(meta,sel,(IMP)HookClassSave,(IMP *)&gOrigClassSave);
        hooked = YES;
    }
    gInstalled = hooked;
    AppendDebug(@{@"event":@"schedule-mirror-hook", @"instance":@(instanceMethod != NULL), @"class":@(classMethod != NULL)});
}

%ctor {
    @autoreleasepool {
        dispatch_async(dispatch_get_main_queue(),^{ InstallHooks(); });
    }
}
