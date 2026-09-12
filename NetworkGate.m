#import <Foundation/Foundation.h>
#import <sys/file.h>
#import <fcntl.h>
#import <unistd.h>

static NSString * const kDebugPath = @"/var/mobile/Library/Preferences/com.551.watusischeduledmsgfix-debug.plist";
static const char *kDebugLockPath = "/var/mobile/Library/Preferences/com.551.watusischeduledmsgfix-debug.lock";

static void AppendDebug(NSDictionary *fields) {
    int fd = open(kDebugLockPath,O_CREAT|O_RDWR,0644);
    if (fd >= 0) flock(fd,LOCK_EX);
    @autoreleasepool {
        NSDictionary *old = [NSDictionary dictionaryWithContentsOfFile:kDebugPath];
        NSMutableArray *events = [NSMutableArray array];
        if ([old[@"events"] isKindOfClass:[NSArray class]]) [events addObjectsFromArray:old[@"events"]];
        NSMutableDictionary *event = [NSMutableDictionary dictionaryWithDictionary:fields ?: @{}];
        event[@"date"] = [NSDate date];
        event[@"process"] = @"network-gate";
        [events addObject:event];
        while (events.count > 100) [events removeObjectAtIndex:0];
        [@{@"version":@"3.1.3",@"date":[NSDate date],@"events":events} writeToFile:kDebugPath atomically:YES];
    }
    if (fd >= 0) { flock(fd,LOCK_UN); close(fd); }
}

static BOOL WhatsAppInternetReady(NSString **detailOut) {
    NSURL *url = [NSURL URLWithString:@"https://www.whatsapp.com/favicon.ico"];
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url
                                                           cachePolicy:NSURLRequestReloadIgnoringLocalCacheData
                                                       timeoutInterval:6.0];
    request.HTTPMethod = @"HEAD";
    [request setValue:@"no-cache" forHTTPHeaderField:@"Cache-Control"];
    [request setValue:@"no-cache" forHTTPHeaderField:@"Pragma"];

    NSURLResponse *response = nil;
    NSError *error = nil;
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    [NSURLConnection sendSynchronousRequest:request returningResponse:&response error:&error];
#pragma clang diagnostic pop

    NSInteger status = 0;
    if ([response isKindOfClass:[NSHTTPURLResponse class]]) status = [(NSHTTPURLResponse *)response statusCode];

    BOOL ready = (!error && status >= 200 && status < 500);
    if (detailOut) {
        if (ready) *detailOut = [NSString stringWithFormat:@"http-%ld",(long)status];
        else if (error) *detailOut = [NSString stringWithFormat:@"%@:%ld",error.domain ?: @"network-error",(long)error.code];
        else *detailOut = [NSString stringWithFormat:@"http-%ld",(long)status];
    }
    return ready;
}

int main(int argc, char *argv[]) {
    @autoreleasepool {
        (void)argc; (void)argv;

        NSString *networkDetail = nil;
        BOOL ready = WhatsAppInternetReady(&networkDetail);
        AppendDebug(@{@"event":@"network-gate",
                      @"result":ready ? @"online" : @"waiting-for-internet",
                      @"detail":networkDetail ?: @"unknown"});
        if (!ready) return 0;

        NSString *core = @"/var/jb/usr/bin/WatusiShortcutSendCore";
        if (![[NSFileManager defaultManager] isExecutableFileAtPath:core]) core = @"/usr/bin/WatusiShortcutSendCore";
        if (![[NSFileManager defaultManager] isExecutableFileAtPath:core]) {
            AppendDebug(@{@"event":@"network-gate",@"result":@"core-not-found"});
            return 1;
        }

        const char *tool = core.fileSystemRepresentation;
        char *const execArgv[] = {(char *)tool,NULL};
        execv(tool,execArgv);

        AppendDebug(@{@"event":@"network-gate",@"result":@"exec-failed",@"errno":@(errno)});
        return 1;
    }
}
