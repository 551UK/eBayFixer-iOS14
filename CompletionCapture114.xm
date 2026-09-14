#import <Foundation/Foundation.h>

static NSString *EB114CaptureKind(NSURL *url) {
    NSString *path = url.path.lowercaseString ?: @"";
    if ([path containsString:@"/experience/shopping/v1/home"] ||
        [path containsString:@"/experience/vertical_landing/v1/get_homepage"]) return @"HOME";
    if ([path containsString:@"/experience/listing_details/v1/view_item"] ||
        [path containsString:@"/experience/listing_details/v2/view_item"]) return @"ITEM";
    if ([path containsString:@"/experience/vertical_landing/v1/module_provider"]) return @"HOME_PROVIDER";
    if ([path containsString:@"/experience/listing_details/v2/module_provider"] ||
        [path containsString:@"/experience/listing_details/v2/preview_draft_listing"] ||
        [path containsString:@"/experience/listing_details/v2/quick_view"]) return @"ITEM_PROVIDER";
    return nil;
}

static NSString *EB114CaptureDocuments(void) {
    NSArray *paths = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
    return paths.firstObject ?: NSTemporaryDirectory();
}

static void EB114CaptureLog(NSString *line) {
    if (!line.length) return;
    NSString *path = [EB114CaptureDocuments() stringByAppendingPathComponent:@"eBayFixer.log"];
    if (![[NSFileManager defaultManager] fileExistsAtPath:path]) {
        [[NSFileManager defaultManager] createFileAtPath:path contents:nil attributes:nil];
    }
    NSFileHandle *handle = [NSFileHandle fileHandleForWritingAtPath:path];
    if (!handle) return;
    NSString *full = [NSString stringWithFormat:@"%@ %@\n", [NSDate date], line];
    @try {
        [handle seekToEndOfFile];
        [handle writeData:[full dataUsingEncoding:NSUTF8StringEncoding]];
        [handle closeFile];
    } @catch (__unused NSException *exception) {}
}

static NSString *EB114TopLevelSummary(NSData *data) {
    if (!data.length) return @"empty";
    NSError *error = nil;
    id json = [NSJSONSerialization JSONObjectWithData:data options:0 error:&error];
    if ([json isKindOfClass:[NSDictionary class]]) {
        NSArray *keys = [[(NSDictionary *)json allKeys] sortedArrayUsingComparator:^NSComparisonResult(id a, id b) {
            return [[a description] compare:[b description]];
        }];
        return [NSString stringWithFormat:@"keys=%@", keys];
    }
    if ([json isKindOfClass:[NSArray class]]) {
        return [NSString stringWithFormat:@"array=%lu", (unsigned long)[(NSArray *)json count]];
    }
    return [NSString stringWithFormat:@"not-json=%@/%ld", error.domain ?: @"none", (long)error.code];
}

static void EB114SaveCompletionResponse(NSString *kind, NSData *data, NSURLResponse *response, NSError *error) {
    if (!kind.length) return;
    NSInteger status = [response isKindOfClass:[NSHTTPURLResponse class]] ? [(NSHTTPURLResponse *)response statusCode] : 0;
    EB114CaptureLog([NSString stringWithFormat:@"COMPLETION_BODY %@ status=%ld bytes=%lu error=%@/%ld %@",
                     kind, (long)status, (unsigned long)data.length,
                     error.domain ?: @"none", (long)error.code, EB114TopLevelSummary(data)]);
    if (!data.length) return;
    NSString *file = [NSString stringWithFormat:@"eBayFixer-%@-response.json", kind];
    [data writeToFile:[EB114CaptureDocuments() stringByAppendingPathComponent:file] atomically:YES];
}

%hook NSURLSession

- (NSURLSessionDataTask *)dataTaskWithRequest:(NSURLRequest *)request completionHandler:(void (^)(NSData *, NSURLResponse *, NSError *))handler {
    NSString *kind = EB114CaptureKind(request.URL);
    if (!kind) return %orig;

    void (^wrapped)(NSData *, NSURLResponse *, NSError *) = ^(NSData *data, NSURLResponse *response, NSError *error) {
        EB114SaveCompletionResponse(kind, data, response, error);
        if (handler) handler(data, response, error);
    };
    return %orig(request, wrapped);
}

- (NSURLSessionUploadTask *)uploadTaskWithRequest:(NSURLRequest *)request fromData:(NSData *)bodyData completionHandler:(void (^)(NSData *, NSURLResponse *, NSError *))handler {
    NSString *kind = EB114CaptureKind(request.URL);
    if (!kind) return %orig;

    void (^wrapped)(NSData *, NSURLResponse *, NSError *) = ^(NSData *data, NSURLResponse *response, NSError *error) {
        EB114SaveCompletionResponse(kind, data, response, error);
        if (handler) handler(data, response, error);
    };
    return %orig(request, bodyData, wrapped);
}

%end

%ctor {
    if (![[[NSBundle mainBundle] bundleIdentifier] isEqualToString:@"com.ebay.iphone"]) return;
    %init;
}
