#import <Foundation/Foundation.h>

static BOOL WSSMFIsWhatsAppBundle(NSString *bundleID) {
    if (![bundleID isKindOfClass:[NSString class]]) return NO;
    return [bundleID isEqualToString:@"net.whatsapp.WhatsApp"] ||
           [bundleID isEqualToString:@"net.whatsapp.WhatsAppSMB"];
}

static NSString *WSSMFBundleIdentifier(id application) {
    if ([application isKindOfClass:[NSString class]]) {
        return WSSMFIsWhatsAppBundle(application) ? application : nil;
    }

    for (NSString *name in @[@"bundleIdentifier", @"bundleID", @"applicationBundleIdentifier", @"identifier"]) {
        SEL selector = NSSelectorFromString(name);
        @try {
            if ([application respondsToSelector:selector]) {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
                id value = [application performSelector:selector];
#pragma clang diagnostic pop
                if ([value isKindOfClass:[NSString class]] && WSSMFIsWhatsAppBundle(value)) {
                    return value;
                }
            }
        } @catch (__unused NSException *exception) {}
    }

    return nil;
}

%hook CSDVoIPApplicationController

- (BOOL)_isApplicationPreventedFromBeingLaunched:(id)application {
    NSString *bundleID = WSSMFBundleIdentifier(application);
    if (WSSMFIsWhatsAppBundle(bundleID)) {
        return NO;
    }
    return %orig;
}

%end
