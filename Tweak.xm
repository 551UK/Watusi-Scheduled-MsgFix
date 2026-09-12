#import <Foundation/Foundation.h>
#import <objc/message.h>
#import <unistd.h>

static NSString * const WSSMFVersion = @"1.0.11";
static NSString * const WSSMFWhatsAppBundle = @"net.whatsapp.WhatsApp";
static NSString * const WSSMFWhatsAppBusinessBundle = @"net.whatsapp.WhatsAppSMB";
static NSString * const WSSMFDebugPath = @"/var/mobile/Library/Preferences/com.551.watusischeduledmsgfix-debug.plist";

static BOOL WSSMFIsWhatsAppBundle(NSString *bundleID) {
    return [bundleID isKindOfClass:[NSString class]] &&
           ([bundleID isEqualToString:WSSMFWhatsAppBundle] ||
            [bundleID isEqualToString:WSSMFWhatsAppBusinessBundle]);
}

static id WSSMFSafeValue(id object, NSString *name) {
    if (!object || !name.length || object == [NSNull null]) return nil;
    SEL selector = NSSelectorFromString(name);
    @try {
        if ([object respondsToSelector:selector]) {
            return ((id (*)(id, SEL))objc_msgSend)(object, selector);
        }
        return [object valueForKey:name];
    } @catch (__unused NSException *exception) {
        return nil;
    }
}

static NSString *WSSMFBundleIdentifier(id object) {
    if ([object isKindOfClass:[NSString class]] && WSSMFIsWhatsAppBundle(object)) {
        return object;
    }

    for (NSString *name in @[@"bundleIdentifier", @"bundleID", @"applicationBundleIdentifier", @"identifier"]) {
        id value = WSSMFSafeValue(object, name);
        if ([value isKindOfClass:[NSString class]] && WSSMFIsWhatsAppBundle(value)) {
            return value;
        }
    }
    return nil;
}

static void WSSMFWriteDebug(NSDictionary *extra) {
    NSMutableDictionary *debug = [NSMutableDictionary dictionary];
    debug[@"version"] = WSSMFVersion;
    debug[@"date"] = [NSDate date];
    debug[@"pid"] = @((int)getpid());
    debug[@"process"] = [[NSProcessInfo processInfo] processName] ?: @"unknown";
    if (extra) [debug addEntriesFromDictionary:extra];
    [debug writeToFile:WSSMFDebugPath atomically:YES];
}

%hook CSDVoIPApplicationController

- (BOOL)_isApplicationPreventedFromBeingLaunched:(id)application {
    NSString *bundleID = WSSMFBundleIdentifier(application);
    if (WSSMFIsWhatsAppBundle(bundleID)) {
        WSSMFWriteDebug(@{
            @"event": @"launch-bypass",
            @"bundleID": bundleID,
            @"result": @"allowed-whatsapp-launch"
        });
        return NO;
    }
    return %orig;
}

%end

%ctor {
    @autoreleasepool {
        WSSMFWriteDebug(@{
            @"event": @"loaded",
            @"result": @"callservicesd-launch-bypass-only"
        });
    }
}
