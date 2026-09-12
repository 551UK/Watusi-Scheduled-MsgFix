#import <Foundation/Foundation.h>
#import <unistd.h>

static BOOL WhatsAppInternetReady(void) {
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

    NSInteger status = [response isKindOfClass:[NSHTTPURLResponse class]] ? [(NSHTTPURLResponse *)response statusCode] : 0;
    return !error && status >= 200 && status < 500;
}

int main(int argc, char *argv[]) {
    @autoreleasepool {
        (void)argc; (void)argv;
        if (!WhatsAppInternetReady()) return 0;

        NSString *core = @"/var/jb/usr/bin/WatusiShortcutSendCore";
        if (![[NSFileManager defaultManager] isExecutableFileAtPath:core]) core = @"/usr/bin/WatusiShortcutSendCore";
        if (![[NSFileManager defaultManager] isExecutableFileAtPath:core]) return 1;

        const char *tool = core.fileSystemRepresentation;
        char *const execArgv[] = {(char *)tool,NULL};
        execv(tool,execArgv);
        return 1;
    }
}
