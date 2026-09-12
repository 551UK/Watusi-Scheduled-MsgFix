#import <Foundation/Foundation.h>
#import <objc/message.h>
#import <dlfcn.h>

static NSString * const WSMFSchedulePrefsName = @"com.fouadraheb.watusi.scheduled-messages.plist";

static id WSMFValue(id obj, NSString *name) {
    if (!obj || !name.length) return nil;
    @try {
        SEL sel = NSSelectorFromString(name);
        if ([obj respondsToSelector:sel]) return ((id(*)(id,SEL))objc_msgSend)(obj,sel);
        return [obj valueForKey:name];
    } @catch (__unused NSException *e) {
        return nil;
    }
}

static BOOL WSMFIsWhatsAppBundle(NSString *bundle) {
    return [bundle isKindOfClass:[NSString class]] &&
        ([bundle isEqualToString:@"net.whatsapp.WhatsApp"] ||
         [bundle isEqualToString:@"net.whatsapp.WhatsAppSMB"]);
}

static NSURL *WSMFDataContainerURL(NSString *bundle) {
    if (!WSMFIsWhatsAppBundle(bundle)) return nil;

    Class proxyClass = NSClassFromString(@"LSApplicationProxy");
    if (!proxyClass) {
        dlopen("/System/Library/Frameworks/CoreServices.framework/CoreServices", RTLD_NOW | RTLD_GLOBAL);
        proxyClass = NSClassFromString(@"LSApplicationProxy");
    }
    SEL proxySel = NSSelectorFromString(@"applicationProxyForIdentifier:");
    if (!proxyClass || ![proxyClass respondsToSelector:proxySel]) return nil;

    id proxy = nil;
    @try {
        proxy = ((id(*)(id,SEL,id))objc_msgSend)(proxyClass,proxySel,bundle);
    } @catch (__unused NSException *e) {
        return nil;
    }
    if (!proxy) return nil;

    id url = WSMFValue(proxy,@"dataContainerURL");
    return [url isKindOfClass:[NSURL class]] ? url : nil;
}

static id WSMFReadPropertyListAtPath(NSString *path, NSString **errorOut) {
    if (!path.length) {
        if (errorOut) *errorOut = @"empty-path";
        return nil;
    }
    NSData *data = [NSData dataWithContentsOfFile:path];
    if (!data.length) {
        if (errorOut) *errorOut = [[NSFileManager defaultManager] fileExistsAtPath:path] ? @"empty-file" : @"file-not-found";
        return nil;
    }
    NSError *error = nil;
    id plist = [NSPropertyListSerialization propertyListWithData:data options:NSPropertyListMutableContainersAndLeaves format:NULL error:&error];
    if (!plist && errorOut) *errorOut = error.localizedDescription ?: @"plist-decode-failed";
    return plist;
}

static id WSMFReadScheduleStore(NSString *bundle, NSString **pathOut, NSString **errorOut) {
    NSURL *container = WSMFDataContainerURL(bundle);
    if (!container) {
        if (errorOut) *errorOut = @"data-container-unavailable";
        return nil;
    }

    NSString *path = [[[container URLByAppendingPathComponent:@"Library" isDirectory:YES]
                        URLByAppendingPathComponent:@"Preferences" isDirectory:YES]
                       URLByAppendingPathComponent:WSMFSchedulePrefsName].path;
    if (pathOut) *pathOut = path;
    id source = WSMFReadPropertyListAtPath(path,errorOut);
    return source;
}

static BOOL WSMFSameID(id value, NSString *sid) {
    if (!value || !sid.length) return NO;
    return [[[value description] lowercaseString] isEqualToString:sid.lowercaseString];
}

static NSDictionary *WSMFFindScheduleDictionary(id obj, NSString *sid, NSUInteger depth) {
    if (!obj || obj == [NSNull null] || !sid.length || depth > 16) return nil;
    if ([obj isKindOfClass:[NSDictionary class]]) {
        NSDictionary *dict = obj;
        id direct = dict[sid];
        if ([direct isKindOfClass:[NSDictionary class]]) return direct;

        for (NSString *key in @[@"identifier",@"scheduleID",@"scheduleId",@"id",@"uuid",@"UUID"]) {
            if (WSMFSameID(dict[key],sid)) return dict;
        }
        for (id value in dict.allValues) {
            NSDictionary *found = WSMFFindScheduleDictionary(value,sid,depth+1);
            if (found) return found;
        }
    } else if ([obj isKindOfClass:[NSArray class]]) {
        for (id value in (NSArray *)obj) {
            NSDictionary *found = WSMFFindScheduleDictionary(value,sid,depth+1);
            if (found) return found;
        }
    }
    return nil;
}

static BOOL WSMFLooksLikeSchedule(NSDictionary *dict) {
    if (![dict isKindOfClass:[NSDictionary class]]) return NO;
    BOOL hasID = dict[@"identifier"] != nil || dict[@"scheduleID"] != nil || dict[@"id"] != nil;
    BOOL hasDate = [dict[@"date"] isKindOfClass:[NSDate class]] || [dict[@"nextTriggerDate"] isKindOfClass:[NSDate class]];
    BOOL hasMessage = [dict[@"messageText"] isKindOfClass:[NSString class]] || [dict[@"message"] isKindOfClass:[NSString class]];
    BOOL hasRecipients = dict[@"recipientsSelected"] != nil || dict[@"recipients"] != nil || dict[@"recipient"] != nil;
    return hasID && hasDate && hasMessage && hasRecipients;
}

static void WSMFCollectSchedules(id obj, NSMutableArray *out, NSUInteger depth) {
    if (!obj || obj == [NSNull null] || depth > 16) return;
    if ([obj isKindOfClass:[NSDictionary class]]) {
        NSDictionary *dict = obj;
        if (WSMFLooksLikeSchedule(dict)) {
            [out addObject:dict];
            return;
        }
        for (id value in dict.allValues) WSMFCollectSchedules(value,out,depth+1);
    } else if ([obj isKindOfClass:[NSArray class]]) {
        for (id value in (NSArray *)obj) WSMFCollectSchedules(value,out,depth+1);
    }
}

static NSArray *WSMFAllSchedules(id source) {
    NSMutableArray *result = [NSMutableArray array];
    WSMFCollectSchedules(source,result,0);
    return result;
}

static NSString *WSMFStringForKeys(NSDictionary *dict, NSArray<NSString *> *keys) {
    if (![dict isKindOfClass:[NSDictionary class]]) return nil;
    for (NSString *key in keys) {
        id value = dict[key];
        if ([value isKindOfClass:[NSString class]] && [value length]) return value;
    }
    return nil;
}

static NSString *WSMFScheduleIdentifier(NSDictionary *schedule) {
    id value = schedule[@"identifier"] ?: schedule[@"scheduleID"] ?: schedule[@"scheduleId"] ?: schedule[@"id"] ?: schedule[@"uuid"] ?: schedule[@"UUID"];
    NSString *sid = [value description];
    return sid.length ? sid : nil;
}

static NSString *WSMFScheduleMessage(NSDictionary *schedule) {
    return WSMFStringForKeys(schedule,@[@"messageText",@"message",@"text",@"content"]);
}

static NSDate *WSMFScheduleDate(NSDictionary *schedule) {
    id date = schedule[@"nextTriggerDate"] ?: schedule[@"date"];
    return [date isKindOfClass:[NSDate class]] ? date : nil;
}

static NSString *WSMFScheduleRepeat(NSDictionary *schedule) {
    id value = schedule[@"repeat"];
    return [value isKindOfClass:[NSString class]] ? value : nil;
}

static BOOL WSMFRepeatIsNone(NSDictionary *schedule) {
    NSString *repeat = WSMFScheduleRepeat(schedule);
    if (!repeat.length) return YES;
    return [repeat caseInsensitiveCompare:@"None"] == NSOrderedSame;
}

static NSString *WSMFNormalizePhone(NSString *value, BOOL *groupFound) {
    if (![value isKindOfClass:[NSString class]] || !value.length) return nil;
    NSString *lower = value.lowercaseString;
    if ([lower containsString:@"@g.us"]) {
        if (groupFound) *groupFound = YES;
        return nil;
    }

    NSString *candidate = value;
    NSRange at = [candidate rangeOfString:@"@"];
    if (at.location != NSNotFound) candidate = [candidate substringToIndex:at.location];

    NSMutableString *digits = [NSMutableString string];
    for (NSUInteger i = 0; i < candidate.length; i++) {
        unichar c = [candidate characterAtIndex:i];
        if (c >= '0' && c <= '9') [digits appendFormat:@"%C",c];
    }
    if (digits.length < 7 || digits.length > 15) return nil;
    if ([digits hasPrefix:@"00"] && digits.length > 2) [digits deleteCharactersInRange:NSMakeRange(0,2)];
    return [NSString stringWithFormat:@"+%@",digits];
}

static NSString *WSMFFindPhone(id obj, NSUInteger depth, BOOL *groupFound) {
    if (!obj || obj == [NSNull null] || depth > 12) return nil;
    if ([obj isKindOfClass:[NSString class]]) return WSMFNormalizePhone(obj,groupFound);
    if ([obj isKindOfClass:[NSArray class]] || [obj isKindOfClass:[NSSet class]]) {
        NSArray *array = [obj isKindOfClass:[NSSet class]] ? [(NSSet *)obj allObjects] : (NSArray *)obj;
        for (id value in array) {
            NSString *phone = WSMFFindPhone(value,depth+1,groupFound);
            if (phone.length) return phone;
        }
        return nil;
    }
    if ([obj isKindOfClass:[NSDictionary class]]) {
        NSDictionary *dict = obj;
        NSArray *priority = @[@"phone",@"phonenumber",@"number",@"jid",@"userjid",@"chatjid",@"user",@"identifier"];
        for (NSString *wanted in priority) {
            for (id rawKey in dict) {
                if (![[[rawKey description] lowercaseString] isEqualToString:wanted]) continue;
                NSString *phone = WSMFFindPhone(dict[rawKey],depth+1,groupFound);
                if (phone.length) return phone;
            }
        }
        for (id value in dict.allValues) {
            NSString *phone = WSMFFindPhone(value,depth+1,groupFound);
            if (phone.length) return phone;
        }
    }
    return nil;
}

static NSString *WSMFSchedulePhone(NSDictionary *schedule, BOOL *groupFound) {
    id recipients = schedule[@"recipientsSelected"] ?: schedule[@"recipients"] ?: schedule[@"recipient"] ?: schedule[@"to"];
    return WSMFFindPhone(recipients,0,groupFound);
}

static uint64_t WSMFFNV1a64(const void *rawBytes, size_t length) {
    const unsigned char *bytes = (const unsigned char *)rawBytes;
    uint64_t hash = 1469598103934665603ULL;
    for (size_t i = 0; i < length; i++) {
        hash ^= bytes[i];
        hash *= 1099511628211ULL;
    }
    return hash;
}

static NSString *WSMFOccurrenceKey(NSString *sid, NSDate *date, NSString *phone, NSString *message) {
    NSString *raw = [NSString stringWithFormat:@"%@|%.0f|%@|%@",sid ?: @"",date ? date.timeIntervalSince1970 : 0,phone ?: @"",message ?: @""];
    NSData *data = [raw dataUsingEncoding:NSUTF8StringEncoding];
    uint64_t hash = WSMFFNV1a64(data.bytes,data.length);
    return [NSString stringWithFormat:@"%@-%016llx",sid ?: @"schedule",(unsigned long long)hash];
}
