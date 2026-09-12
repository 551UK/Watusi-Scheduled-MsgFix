#import <Foundation/Foundation.h>
#import <objc/message.h>

static BOOL IsWhatsAppBundle(NSString *bundleID) {
    return [bundleID isKindOfClass:[NSString class]] &&
           ([bundleID isEqualToString:@"net.whatsapp.WhatsApp"] ||
            [bundleID isEqualToString:@"net.whatsapp.WhatsAppSMB"]);
}

static id SafeValue(id object, NSString *name) {
    if (!object || !name.length || object == [NSNull null]) return nil;
    SEL sel = NSSelectorFromString(name);
    @try {
        if ([object respondsToSelector:sel]) return ((id (*)(id, SEL))objc_msgSend)(object, sel);
        return [object valueForKey:name];
    } @catch (__unused NSException *e) {
        return nil;
    }
}

static NSString *BundleIDForApplication(id application) {
    if ([application isKindOfClass:[NSString class]] && IsWhatsAppBundle(application)) return application;
    for (NSString *key in @[@"bundleIdentifier", @"bundleID", @"applicationBundleIdentifier", @"identifier"]) {
        id value = SafeValue(application, key);
        if ([value isKindOfClass:[NSString class]] && IsWhatsAppBundle(value)) return value;
    }
    return nil;
}

%hook CSDVoIPApplicationController
- (BOOL)_isApplicationPreventedFromBeingLaunched:(id)application {
    NSString *bundleID = BundleIDForApplication(application);
    if (IsWhatsAppBundle(bundleID)) return NO;
    return %orig;
}
%end
