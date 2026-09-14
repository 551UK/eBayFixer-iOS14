#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <WebKit/WebKit.h>
#import <objc/runtime.h>

static NSString *const EBTargetBundleID = @"com.ebay.iphone";
static NSString *const EBTargetVersion = @"6.273.0";
static NSString *const EBOriginalVersion = @"6.96.0";

#pragma mark - Small diagnostic log

static NSString *EBLogPath(void) {
    static NSString *path;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        NSArray *paths = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
        path = [(paths.firstObject ?: NSTemporaryDirectory()) stringByAppendingPathComponent:@"eBayFixer.log"];
    });
    return path;
}

static dispatch_queue_t EBLogQueue(void) {
    static dispatch_queue_t queue;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        queue = dispatch_queue_create("com.551.ebayfixer.log", DISPATCH_QUEUE_SERIAL);
    });
    return queue;
}

static void EBLog(NSString *format, ...) {
    if (!format) return;
    va_list args;
    va_start(args, format);
    NSString *message = [[NSString alloc] initWithFormat:format arguments:args];
    va_end(args);
    if (!message) return;

    NSLog(@"[eBayFixer] %@", message);
    dispatch_async(EBLogQueue(), ^{
        NSString *line = [NSString stringWithFormat:@"%@ %@\n", [NSDate date], message];
        NSData *data = [line dataUsingEncoding:NSUTF8StringEncoding];
        if (![[NSFileManager defaultManager] fileExistsAtPath:EBLogPath()]) {
            [[NSFileManager defaultManager] createFileAtPath:EBLogPath() contents:nil attributes:nil];
        }
        NSFileHandle *handle = [NSFileHandle fileHandleForWritingAtPath:EBLogPath()];
        if (!handle) return;
        @try {
            [handle seekToEndOfFile];
            [handle writeData:data];
            [handle closeFile];
        } @catch (__unused NSException *exception) {}
    });
}

#pragma mark - Helpers

static BOOL EBIsEBayHost(NSString *host) {
    if (![host isKindOfClass:[NSString class]] || host.length == 0) return NO;
    NSString *h = host.lowercaseString;
    return [h containsString:@"ebay.com"] ||
           [h containsString:@"ebay.co.uk"] ||
           [h containsString:@"ebaystatic.com"] ||
           [h containsString:@"ebayimg.com"];
}

static BOOL EBIsDCSURL(NSURL *url) {
    NSString *host = url.host.lowercaseString ?: @"";
    NSString *path = url.path.lowercaseString ?: @"";
    return [host containsString:@"mobidcs"] || [path containsString:@"/mobile/dcs/"];
}

static BOOL EBIsViewItemURL(NSURL *url) {
    NSString *path = url.path.lowercaseString ?: @"";
    return [path containsString:@"listing_details"] ||
           [path containsString:@"listingdetails"] ||
           [path containsString:@"view_item"] ||
           [path containsString:@"module_provider"];
}

static BOOL EBIsHomeURL(NSURL *url) {
    NSString *path = url.path.lowercaseString ?: @"";
    return [path containsString:@"/experience/shopping/v1/home"] ||
           [path containsString:@"vertical_landing"] ||
           [path containsString:@"bullseye"] ||
           [path containsString:@"homepage"] ||
           [path containsString:@"home_screen"];
}

static BOOL EBIsSearchURL(NSURL *url) {
    NSString *path = url.path.lowercaseString ?: @"";
    return [path containsString:@"/experience/search/"] ||
           [path containsString:@"search_results"];
}

static NSString *EBMarker(NSURL *url) {
    if (EBIsDCSURL(url)) return @"DCS";
    if (EBIsViewItemURL(url)) return @"VIEWITEM";
    if (EBIsHomeURL(url)) return @"HOME";
    if (EBIsSearchURL(url)) return @"SEARCH";
    return nil;
}

static NSString *EBSafeURL(NSURL *url) {
    if (!url) return @"(nil)";
    NSURLComponents *parts = [NSURLComponents componentsWithURL:url resolvingAgainstBaseURL:NO];
    if (!parts) return url.host ?: @"(unknown)";
    parts.query = nil;
    parts.fragment = nil;
    return parts.URL.absoluteString ?: url.host ?: @"(unknown)";
}

static NSString *EBRewriteVersionText(NSString *value) {
    if (![value isKindOfClass:[NSString class]] || value.length == 0) return value;

    NSString *out = value;
    for (NSString *old in @[EBOriginalVersion, @"6.267.0", @"6.272.0"]) {
        out = [out stringByReplacingOccurrencesOfString:old withString:EBTargetVersion];
    }
    return out;
}

static BOOL EBIsAppVersionHeader(NSString *field) {
    NSString *f = field.lowercaseString ?: @"";
    // Keep this exact. Apollo's apollographql-client-version is the Apollo
    // library version, not the eBay app version.
    return [f isEqualToString:@"x-ebay-mobile-app-version"] ||
           [f isEqualToString:@"x-ebay-app-version"];
}

static NSString *EBRewriteHeaderValue(NSString *field, NSString *value) {
    if (![value isKindOfClass:[NSString class]]) return value;
    if (EBIsAppVersionHeader(field)) return EBTargetVersion;

    NSString *f = field.lowercaseString ?: @"";
    if ([f isEqualToString:@"user-agent"] ||
        [f isEqualToString:@"x-ebay-mobile-app-info"] ||
        [f isEqualToString:@"x-ebay-c-version"]) {
        return EBRewriteVersionText(value);
    }
    return value;
}

static NSDictionary *EBRewriteHeaders(NSDictionary *headers, NSURL *url) {
    if (![headers isKindOfClass:[NSDictionary class]] || !EBIsEBayHost(url.host)) return headers;

    NSMutableDictionary *out = [headers mutableCopy];
    for (id rawKey in [out.allKeys copy]) {
        if (![rawKey isKindOfClass:[NSString class]]) continue;
        NSString *key = (NSString *)rawKey;
        id rawValue = out[key];
        if (![rawValue isKindOfClass:[NSString class]]) continue;
        out[key] = EBRewriteHeaderValue(key, (NSString *)rawValue);
    }

    out[@"X-EBAY-MOBILE-APP-VERSION"] = EBTargetVersion;
    return out;
}

static NSURL *EBRewriteURL(NSURL *url) {
    if (!url || !EBIsEBayHost(url.host)) return url;

    NSString *original = url.absoluteString ?: @"";
    NSString *rewritten = EBRewriteVersionText(original);

    // 6.96.0 already contains eBay's v2 View Item implementation, but still
    // carries v1 URLs behind feature toggles. 6.192.0 only uses the v2 paths.
    rewritten = [rewritten stringByReplacingOccurrencesOfString:@"/experience/listing_details/v1/view_item"
                                                     withString:@"/experience/listing_details/v2/view_item"];
    rewritten = [rewritten stringByReplacingOccurrencesOfString:@"/experience/listing_details/v1/module_provider"
                                                     withString:@"/experience/listing_details/v2/module_provider"];
    rewritten = [rewritten stringByReplacingOccurrencesOfString:@"/experience/listing_details/v1/preview_draft_listing"
                                                     withString:@"/experience/listing_details/v2/preview_draft_listing"];

    // Do NOT rewrite eBay's DCS /version/1.0.0-seed/config component. It is a
    // DCS configuration/schema version, not CFBundleShortVersionString.

    if ([rewritten isEqualToString:original]) return url;
    return [NSURL URLWithString:rewritten] ?: url;
}

static NSData *EBRewriteBody(NSData *body, NSURL *url) {
    if (!body || body.length == 0 || body.length > (2 * 1024 * 1024) || !EBIsEBayHost(url.host)) return body;
    NSString *text = [[NSString alloc] initWithData:body encoding:NSUTF8StringEncoding];
    if (!text) return body;
    NSString *rewritten = EBRewriteVersionText(text);
    if ([rewritten isEqualToString:text]) return body;
    return [rewritten dataUsingEncoding:NSUTF8StringEncoding] ?: body;
}

static void EBPrepareMutableRequest(NSMutableURLRequest *request) {
    if (!request || !EBIsEBayHost(request.URL.host)) return;

    NSURL *newURL = EBRewriteURL(request.URL);
    if (newURL) request.URL = newURL;

    request.allHTTPHeaderFields = EBRewriteHeaders(request.allHTTPHeaderFields ?: @{}, request.URL);

    NSData *oldBody = request.HTTPBody;
    NSData *newBody = EBRewriteBody(oldBody, request.URL);
    if (oldBody && newBody && ![oldBody isEqualToData:newBody]) {
        request.HTTPBody = newBody;
        [request setValue:[NSString stringWithFormat:@"%lu", (unsigned long)newBody.length]
       forHTTPHeaderField:@"Content-Length"];
    }

    NSString *marker = EBMarker(request.URL);
    if (marker) {
        EBLog(@"REQ %@ %@ %@ appver=%@", marker,
              request.HTTPMethod ?: @"GET", EBSafeURL(request.URL),
              [request valueForHTTPHeaderField:@"X-EBAY-MOBILE-APP-VERSION"] ?: @"(none)");
    }
}

static NSURLRequest *EBPrepareRequest(NSURLRequest *request) {
    if (!request || !EBIsEBayHost(request.URL.host)) return request;
    NSMutableURLRequest *mutable = [request mutableCopy];
    if (!mutable) return request;
    EBPrepareMutableRequest(mutable);
    return mutable;
}

static void EBLogResponse(NSURLResponse *response, NSError *error, NSUInteger bytes) {
    NSURL *url = response.URL;
    NSString *marker = EBMarker(url);
    if (!marker && !error) return;

    NSInteger status = [response isKindOfClass:[NSHTTPURLResponse class]] ?
        [(NSHTTPURLResponse *)response statusCode] : 0;
    EBLog(@"RESP %@ status=%ld bytes=%lu %@ error=%@/%ld %@",
          marker ?: @"NET", (long)status, (unsigned long)bytes,
          EBSafeURL(url), error.domain ?: @"none", (long)error.code,
          error.localizedDescription ?: @"");
}

#pragma mark - App identity / update gate

static BOOL EBIsExpiryAlert(UIViewController *controller) {
    if (![controller isKindOfClass:[UIAlertController class]]) return NO;
    UIAlertController *alert = (UIAlertController *)controller;
    NSString *text = [NSString stringWithFormat:@"%@ %@", alert.title ?: @"", alert.message ?: @""];
    return [text rangeOfString:@"update required" options:NSCaseInsensitiveSearch].location != NSNotFound ||
           [text rangeOfString:@"version has expired" options:NSCaseInsensitiveSearch].location != NSNotFound ||
           [text rangeOfString:@"update ebay" options:NSCaseInsensitiveSearch].location != NSNotFound;
}

%hook NSBundle
- (id)objectForInfoDictionaryKey:(NSString *)key {
    if (self == [NSBundle mainBundle]) {
        if ([key isEqualToString:@"CFBundleShortVersionString"] || [key isEqualToString:@"CFBundleDisplayNameVersion"]) {
            return EBTargetVersion;
        }
    }
    return %orig;
}

- (NSDictionary *)infoDictionary {
    NSDictionary *dictionary = %orig;
    if (self != [NSBundle mainBundle] || !dictionary) return dictionary;
    NSMutableDictionary *copy = [dictionary mutableCopy];
    copy[@"CFBundleShortVersionString"] = EBTargetVersion;
    return copy;
}

- (NSDictionary *)localizedInfoDictionary {
    NSDictionary *dictionary = %orig;
    if (self != [NSBundle mainBundle] || !dictionary) return dictionary;
    NSMutableDictionary *copy = [dictionary mutableCopy];
    if (copy[@"CFBundleShortVersionString"]) copy[@"CFBundleShortVersionString"] = EBTargetVersion;
    return copy;
}
%end

%hook UIViewController
- (void)presentViewController:(UIViewController *)controller animated:(BOOL)animated completion:(void (^)(void))completion {
    if (EBIsExpiryAlert(controller)) {
        EBLog(@"Blocked eBay update/expired-version alert");
        if (completion) completion();
        return;
    }
    %orig;
}
%end

%hook UIAlertView
- (void)show {
    NSString *text = [NSString stringWithFormat:@"%@ %@", self.title ?: @"", self.message ?: @""];
    if ([text rangeOfString:@"update required" options:NSCaseInsensitiveSearch].location != NSNotFound ||
        [text rangeOfString:@"version has expired" options:NSCaseInsensitiveSearch].location != NSNotFound ||
        [text rangeOfString:@"update ebay" options:NSCaseInsensitiveSearch].location != NSNotFound) {
        EBLog(@"Blocked legacy eBay update/expired-version alert");
        return;
    }
    %orig;
}
%end

#pragma mark - Force newer native flows already present in 6.96.0

%hook _TtC11ItemProduct29ObjCItemProductFeatureToggles
- (BOOL)useViewItemExperienceServiceRaptorIOURL {
    return YES;
}
- (BOOL)useViewItemExperienceServiceRaptorIOPreviewURL {
    return YES;
}
%end

%hook _TtC14HomePageModule26ObjCHomePageFeatureToggles
- (BOOL)vlpF90 {
    return YES;
}
- (BOOL)vlpF90KillSwitch {
    return NO;
}
- (BOOL)preprodServiceVLPHomepage {
    return NO;
}
- (BOOL)preprodServiceVLPSegmentation {
    return NO;
}
%end

#pragma mark - eBay request builders

%hook NSMutableURLRequest
- (void)setURL:(NSURL *)URL {
    %orig(EBRewriteURL(URL));
}

- (void)setValue:(NSString *)value forHTTPHeaderField:(NSString *)field {
    if (EBIsEBayHost(self.URL.host)) {
        %orig(EBRewriteHeaderValue(field, value), field);
        return;
    }
    %orig;
}

- (void)addValue:(NSString *)value forHTTPHeaderField:(NSString *)field {
    if (EBIsEBayHost(self.URL.host)) {
        %orig(EBRewriteHeaderValue(field, value), field);
        return;
    }
    %orig;
}

- (void)setAllHTTPHeaderFields:(NSDictionary<NSString *, NSString *> *)headers {
    if (EBIsEBayHost(self.URL.host)) {
        %orig(EBRewriteHeaders(headers, self.URL));
        return;
    }
    %orig;
}
%end

%hook NSURLSessionConfiguration
- (void)setHTTPAdditionalHeaders:(NSDictionary *)headers {
    NSMutableDictionary *copy = [headers mutableCopy];
    for (id rawKey in [copy.allKeys copy]) {
        if (![rawKey isKindOfClass:[NSString class]]) continue;
        id rawValue = copy[rawKey];
        if (![rawValue isKindOfClass:[NSString class]]) continue;
        NSString *key = (NSString *)rawKey;
        copy[key] = EBRewriteHeaderValue(key, (NSString *)rawValue);
    }
    %orig(copy ?: headers);
}
%end

%hook APIRequest
- (void)addStandardHeadersWithUrlRequest:(NSMutableURLRequest *)request {
    %orig;
    EBPrepareMutableRequest(request);
}
- (void)configureURLRequestHeaders:(NSMutableURLRequest *)request {
    %orig;
    EBPrepareMutableRequest(request);
}
%end

%hook EBayRequest
- (void)configureURLRequestHeaders:(NSMutableURLRequest *)request {
    %orig;
    EBPrepareMutableRequest(request);
}
%end

#pragma mark - Foundation networking

%hook NSURLSession
- (NSURLSessionDataTask *)dataTaskWithRequest:(NSURLRequest *)request completionHandler:(void (^)(NSData *, NSURLResponse *, NSError *))completionHandler {
    NSURLRequest *prepared = EBPrepareRequest(request);
    void (^wrapped)(NSData *, NSURLResponse *, NSError *) = ^(NSData *data, NSURLResponse *response, NSError *error) {
        EBLogResponse(response, error, data.length);
        if (completionHandler) completionHandler(data, response, error);
    };
    return %orig(prepared, wrapped);
}

- (NSURLSessionDataTask *)dataTaskWithRequest:(NSURLRequest *)request {
    return %orig(EBPrepareRequest(request));
}

- (NSURLSessionUploadTask *)uploadTaskWithRequest:(NSURLRequest *)request fromData:(NSData *)bodyData completionHandler:(void (^)(NSData *, NSURLResponse *, NSError *))completionHandler {
    NSURLRequest *prepared = EBPrepareRequest(request);
    NSData *body = EBRewriteBody(bodyData, prepared.URL);
    void (^wrapped)(NSData *, NSURLResponse *, NSError *) = ^(NSData *data, NSURLResponse *response, NSError *error) {
        EBLogResponse(response, error, data.length);
        if (completionHandler) completionHandler(data, response, error);
    };
    return %orig(prepared, body, wrapped);
}

- (NSURLSessionDownloadTask *)downloadTaskWithRequest:(NSURLRequest *)request completionHandler:(void (^)(NSURL *, NSURLResponse *, NSError *))completionHandler {
    NSURLRequest *prepared = EBPrepareRequest(request);
    void (^wrapped)(NSURL *, NSURLResponse *, NSError *) = ^(NSURL *location, NSURLResponse *response, NSError *error) {
        EBLogResponse(response, error, 0);
        if (completionHandler) completionHandler(location, response, error);
    };
    return %orig(prepared, wrapped);
}
%end

%hook NSURLConnection
- (instancetype)initWithRequest:(NSURLRequest *)request delegate:(id)delegate startImmediately:(BOOL)startImmediately {
    return %orig(EBPrepareRequest(request), delegate, startImmediately);
}

+ (void)sendAsynchronousRequest:(NSURLRequest *)request queue:(NSOperationQueue *)queue completionHandler:(void (^)(NSURLResponse *, NSData *, NSError *))handler {
    NSURLRequest *prepared = EBPrepareRequest(request);
    void (^wrapped)(NSURLResponse *, NSData *, NSError *) = ^(NSURLResponse *response, NSData *data, NSError *error) {
        EBLogResponse(response, error, data.length);
        if (handler) handler(response, data, error);
    };
    %orig(prepared, queue, wrapped);
}
%end

%hook WKWebView
- (WKNavigation *)loadRequest:(NSURLRequest *)request {
    return %orig(EBPrepareRequest(request));
}
%end

%ctor {
    @autoreleasepool {
        if (![[NSBundle mainBundle].bundleIdentifier isEqualToString:EBTargetBundleID]) return;
        [[NSFileManager defaultManager] removeItemAtPath:EBLogPath() error:nil];
        EBLog(@"eBayFixer loaded: native 6.96.0 -> app identity %@; DCS schema preserved; VLP Home + View Item v2 enabled.", EBTargetVersion);
    }
}
