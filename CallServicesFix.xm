#import <Foundation/Foundation.h>
#import <objc/message.h>

static NSString * const WSSMFWhatsAppBundle = @"net.whatsapp.WhatsApp";
static NSString * const WSSMFWhatsAppBusinessBundle = @"net.whatsapp.WhatsAppSMB";

static BOOL WSSMFIsWhatsAppBundle(NSString *bundleID) {
    return [bundleID isKindOfClass:[NSString class]] &&
           ([bundleID isEqualToString:WSSMFWhatsAppBundle] ||
            [bundleID isEqualToString:WSSMFWhatsAppBusinessBundle]);
}

static id WSSMFSafeValue(id object, NSString *name) {
    if (!object || !name.length || object == [NSNull null]) return nil;
    SEL selector = NSSelectorFromString(name);
    @try {
        if ([object respondsToSelector:selector]) return ((id (*)(id, SEL))objc_msgSend)(object, selector);
        return [object valueForKey:name];
    } @catch (__unused NSException *exception) {
        return nil;
    }
}

static NSString *WSSMFBundleIdentifier(id object) {
    if ([object isKindOfClass:[NSString class]] && WSSMFIsWhatsAppBundle(object)) return object;
    for (NSString *name in @[@"bundleIdentifier", @"bundleID", @"applicationBundleIdentifier", @"identifier"]) {
        id value = WSSMFSafeValue(object, name);
        if ([value isKindOfClass:[NSString class]] && WSSMFIsWhatsAppBundle(value)) return value;
    }
    return nil;
}

%hook CSDVoIPApplicationController

- (BOOL)_isApplicationPreventedFromBeingLaunched:(id)application {
    NSString *bundleID = WSSMFBundleIdentifier(application);
    if (WSSMFIsWhatsAppBundle(bundleID)) return NO;
    return %orig;
}

%end
