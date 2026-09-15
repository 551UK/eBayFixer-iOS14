#import <Foundation/Foundation.h>

static NSString *EB110LogPath(void) {
    NSArray *paths = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
    NSString *dir = paths.firstObject ?: NSTemporaryDirectory();
    return [dir stringByAppendingPathComponent:@"eBayFixer.log"];
}

static void EB110Log(NSString *format, ...) {
    va_list args;
    va_start(args, format);
    NSString *message = [[NSString alloc] initWithFormat:format arguments:args];
    va_end(args);
    if (!message.length) return;

    NSString *path = EB110LogPath();
    if (![[NSFileManager defaultManager] fileExistsAtPath:path]) {
        [[NSFileManager defaultManager] createFileAtPath:path contents:nil attributes:nil];
    }
    NSFileHandle *handle = [NSFileHandle fileHandleForWritingAtPath:path];
    if (!handle) return;

    NSString *line = [NSString stringWithFormat:@"%@ %@\n", [NSDate date], message];
    @try {
        [handle seekToEndOfFile];
        [handle writeData:[line dataUsingEncoding:NSUTF8StringEncoding]];
        [handle closeFile];
    } @catch (__unused NSException *exception) {}
}

static NSString *EB110Kind(NSURL *url) {
    NSString *path = url.path.lowercaseString ?: @"";
    NSString *host = url.host.lowercaseString ?: @"";

    if ([host containsString:@"mobidcsng.ebay.com"] && [path containsString:@"/mobile/dcs/"]) return @"HOME_DCS";
    if ([path containsString:@"/experience/shopping/v1/homepage/user_segmentation"] ||
        [path containsString:@"homepage/user_segmentation"] ||
        ([path containsString:@"vlp"] && [path containsString:@"segmentation"])) return @"HOME_SEGMENTATION";
    if ([path containsString:@"/experience/vertical_landing/v1/module_provider"]) return @"HOME_PROVIDER";
    if ([path containsString:@"/experience/listing_details/v2/module_provider"] ||
        [path containsString:@"/experience/listing_details/v2/preview_draft_listing"] ||
        [path containsString:@"/experience/listing_details/v2/quick_view"]) return @"ITEM_PROVIDER";
    if ([path containsString:@"/experience/shopping/v1/home"] ||
        [path containsString:@"/experience/vertical_landing/v1/get_homepage"]) return @"HOME";
    if ([path containsString:@"/experience/listing_details/"] || [path containsString:@"/view_item"]) return @"ITEM";
    if ([path containsString:@"/experience/search/"] || [path containsString:@"search_results"]) return @"SEARCH";
    return nil;
}

static void EB110Poll(NSURLSessionTask *task, NSString *kind, NSTimeInterval delay) {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        NSURLResponse *response = task.response;
        NSInteger status = [response isKindOfClass:[NSHTTPURLResponse class]] ? [(NSHTTPURLResponse *)response statusCode] : 0;
        NSError *error = task.error;
        EB110Log(@"TASK %@ %.2fs state=%ld status=%ld received=%lld expected=%lld error=%@/%ld",
                 kind, delay, (long)task.state, (long)status,
                 task.countOfBytesReceived, task.countOfBytesExpectedToReceive,
                 error.domain ?: @"none", (long)error.code);
    });
}

%hook NSURLSessionTask

- (void)resume {
    NSURLRequest *request = self.currentRequest ?: self.originalRequest;
    NSString *kind = EB110Kind(request.URL);
    if (kind) {
        EB110Log(@"REQ %@ %@", kind, request.URL.absoluteString ?: @"(nil)");
        for (NSNumber *delay in @[@0.25, @1.0, @2.0, @4.0, @8.0]) {
            EB110Poll(self, kind, delay.doubleValue);
        }
    }
    %orig;
}

%end

%ctor {
    if (![[[NSBundle mainBundle] bundleIdentifier] isEqualToString:@"com.ebay.iphone"]) return;
    [[NSFileManager defaultManager] removeItemAtPath:EB110LogPath() error:nil];
    %init;
    EB110Log(@"HOME_NATIVE140 passive_network_diag=1");
}
