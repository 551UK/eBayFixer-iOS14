#import <Foundation/Foundation.h>

static NSString *const EB114HomeVLPPath = @"/experience/vertical_landing/v1/get_homepage";
static NSString *const EB114LegacyHomePath = @"/experience/shopping/v1/home";

// Component names present in both the real 6.96 HomePageModule VLP parser and
// the 6.192 Home VLP implementation. This avoids sending the old Answers Home
// component list to the newer Vertical Landing service.
static NSString *const EB114HomeComponents = @"NAVIGATION_IMAGE_GRID,ITEMS_CAROUSEL,ITEM_CARD_LIST,PAGE_TITLE,MERCH_GRID,NAVIGATION_BAR,COLD_START_TOP_OF_PAGE,TOP_OF_PAGE_WITH_VEHICLE,RECOMMENDED_ACTIONS,CARD_CONTAINERS_CAROUSEL_GROUP,ITEM_CARD_CAROUSEL,USER_GARAGE_MODULE";

static BOOL EB114IsEBayURL(NSURL *url) {
    NSString *host = url.host.lowercaseString ?: @"";
    return [host isEqualToString:@"ebay.com"] ||
           [host hasSuffix:@".ebay.com"] ||
           [host hasSuffix:@".ebay.co.uk"];
}

static NSString *EB114LogPath(void) {
    NSArray *paths = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
    NSString *dir = paths.firstObject ?: NSTemporaryDirectory();
    return [dir stringByAppendingPathComponent:@"eBayFixer.log"];
}

static void EB114Log(NSString *format, ...) {
    if (!format) return;
    va_list args;
    va_start(args, format);
    NSString *message = [[NSString alloc] initWithFormat:format arguments:args];
    va_end(args);
    if (!message) return;

    NSString *line = [NSString stringWithFormat:@"%@ %@\n", [NSDate date], message];
    NSData *data = [line dataUsingEncoding:NSUTF8StringEncoding];
    NSString *path = EB114LogPath();
    if (![[NSFileManager defaultManager] fileExistsAtPath:path]) {
        [[NSFileManager defaultManager] createFileAtPath:path contents:nil attributes:nil];
    }
    NSFileHandle *handle = [NSFileHandle fileHandleForWritingAtPath:path];
    if (!handle) return;
    @try {
        [handle seekToEndOfFile];
        [handle writeData:data];
        [handle closeFile];
    } @catch (__unused NSException *exception) {}
}

static NSURL *EB114RewriteHomeURL(NSURL *url) {
    if (!url || !EB114IsEBayURL(url)) return url;

    NSString *path = url.path ?: @"";
    if (![path isEqualToString:EB114LegacyHomePath] && ![path isEqualToString:EB114HomeVLPPath]) {
        return url;
    }

    NSURLComponents *components = [NSURLComponents componentsWithURL:url resolvingAgainstBaseURL:NO];
    if (!components) return url;

    // Make the migration independent of hook ordering with EndpointFix111.
    components.path = EB114HomeVLPPath;

    NSMutableArray<NSURLQueryItem *> *items = [components.queryItems mutableCopy] ?: [NSMutableArray array];
    BOOL replaced = NO;
    for (NSUInteger i = 0; i < items.count; i++) {
        NSURLQueryItem *item = items[i];
        if ([item.name isEqualToString:@"supported_ux_components"]) {
            items[i] = [NSURLQueryItem queryItemWithName:item.name value:EB114HomeComponents];
            replaced = YES;
        }
    }
    if (!replaced) {
        [items addObject:[NSURLQueryItem queryItemWithName:@"supported_ux_components" value:EB114HomeComponents]];
    }
    components.queryItems = items;

    NSURL *rewritten = components.URL ?: url;
    if (![rewritten.absoluteString isEqualToString:url.absoluteString]) {
        EB114Log(@"CONTRACT HOME %@ -> %@", url.absoluteString ?: @"(nil)", rewritten.absoluteString ?: @"(nil)");
    }
    return rewritten;
}

static NSURLRequest *EB114RewriteRequest(NSURLRequest *request) {
    if (!request) return request;
    NSURL *newURL = EB114RewriteHomeURL(request.URL);
    if (!newURL || [newURL isEqual:request.URL]) return request;
    NSMutableURLRequest *copy = [request mutableCopy];
    copy.URL = newURL;
    return copy ?: request;
}

%hook NSMutableURLRequest

- (void)setURL:(NSURL *)URL {
    NSURL *rewritten = EB114RewriteHomeURL(URL);
    %orig(rewritten);
}

%end

%hook NSURLSession

- (NSURLSessionDataTask *)dataTaskWithRequest:(NSURLRequest *)request completionHandler:(void (^)(NSData *, NSURLResponse *, NSError *))handler {
    NSURLRequest *rewritten = EB114RewriteRequest(request);
    return %orig(rewritten, handler);
}

- (NSURLSessionDataTask *)dataTaskWithRequest:(NSURLRequest *)request {
    NSURLRequest *rewritten = EB114RewriteRequest(request);
    return %orig(rewritten);
}

- (NSURLSessionUploadTask *)uploadTaskWithRequest:(NSURLRequest *)request fromData:(NSData *)bodyData completionHandler:(void (^)(NSData *, NSURLResponse *, NSError *))handler {
    NSURLRequest *rewritten = EB114RewriteRequest(request);
    return %orig(rewritten, bodyData, handler);
}

%end

%ctor {
    if (![[[NSBundle mainBundle] bundleIdentifier] isEqualToString:@"com.ebay.iphone"]) return;
    %init;
}
