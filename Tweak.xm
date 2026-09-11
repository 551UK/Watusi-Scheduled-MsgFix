#import <Foundation/Foundation.h>

static NSString *WSSMFBundleIdentifier(id application) {
    if (!application) return nil;

    if ([application isKindOfClass:[NSString class]]) {
        return (NSString *)application;
    }

    NSArray<NSString *> *selectorNames = @[
        @"bundleIdentifier",
        @"bundleID",
        @"applicationBundleIdentifier",
        @"identifier"
    ];

    for (NSString *selectorName in selectorNames) {
        SEL selector = NSSelectorFromString(selectorName);
        if ([application respondsToSelector:selector]) {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
            id value = [application performSelector:selector];
#pragma clang diagnostic pop
            if ([value isKindOfClass:[NSString class]]) {
                return (NSString *)value;
            }
        }
    }

    return nil;
}

static BOOL WSSMFIsWhatsAppBundle(NSString *bundleID) {
    if (!bundleID) return NO;

    return [bundleID isEqualToString:@"net.whatsapp.WhatsApp"] ||
           [bundleID isEqualToString:@"net.whatsapp.WhatsAppSMB"];
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
