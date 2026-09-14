#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <substrate.h>

static NSString *const EB107BundleID = @"com.ebay.iphone";
static NSString *const EB107VisibleVersion = @"6.273.0";
static NSString *const EB107APICompatVersion = @"6.192.0";
static NSString *const EB107OriginalVersion = @"6.96.0";
static BOOL EB107ItemV2Ready = NO;

static BOOL EB107IsEBayHost(NSString *host) {
    if (![host isKindOfClass:[NSString class]] || host.length == 0) return NO;
    NSString *h = host.lowercaseString;
    return [h isEqualToString:@"ebay.com"] || [h hasSuffix:@".ebay.com"] ||
           [h hasSuffix:@".ebay.co.uk"] || [h hasSuffix:@".ebaystatic.com"] ||
           [h hasSuffix:@".ebayimg.com"];
}

static BOOL EB107IsDCSURL(NSURL *url) {
    if (!url) return NO;
    NSString *host = url.host.lowercaseString ?: @"";
    NSString *path = url.path.lowercaseString ?: @"";
    return [host containsString:@"mobidcs"] || [host containsString:@"dcsng"] ||
           [path containsString:@"/mobile/dcs/"];
}

static BOOL EB107IsAPIURL(NSURL *url) {
    if (!url) return NO;
    NSString *host = url.host.lowercaseString ?: @"";
    NSString *path = url.path.lowercaseString ?: @"";

    // eBay 6.96 sends Home through APISD rather than api.ebay.com.
    // Native experience-service calls should use the known-working 6.192.0
    // client identity while update/DCS checks continue to see 6.273.0.
    if ([host isEqualToString:@"apisd.ebay.com"] || [host hasPrefix:@"apisd.ebay."]) return YES;
    if ([path hasPrefix:@"/experience/"]) return YES;

    return [host isEqualToString:@"api.ebay.com"] || [host hasPrefix:@"api.ebay."] ||
           [host isEqualToString:@"apima.qa.ebay.com"] || [host hasSuffix:@".api.ebay.com"];
}

static BOOL EB107IsHomeURL(NSURL *url) {
    NSString *path = url.path.lowercaseString ?: @"";
    return [path containsString:@"/experience/vertical_landing/v1/get_homepage"] ||
           [path containsString:@"/experience/shopping/v1/homepage/user_segmentation"] ||
           [path containsString:@"/experience/shopping/v1/home"];
}

static NSString *EB107VersionForURL(NSURL *url) {
    if (EB107IsDCSURL(url)) return EB107VisibleVersion;
    if (EB107IsAPIURL(url)) return EB107APICompatVersion;
    return EB107VisibleVersion;
}

static NSString *EB107RewriteVersionText(NSString *value, NSString *target) {
    if (![value isKindOfClass:[NSString class]] || value.length == 0) return value;
    NSString *out = value;
    for (NSString *old in @[EB107OriginalVersion, @"6.267.0", @"6.272.0", EB107VisibleVersion, EB107APICompatVersion]) {
        if (![old isEqualToString:target]) {
            out = [out stringByReplacingOccurrencesOfString:old withString:target];
        }
    }
    return out;
}

static BOOL EB107IsVersionHeader(NSString *field) {
    NSString *f = field.lowercaseString ?: @"";
    return [f isEqualToString:@"x-ebay-mobile-app-version"] ||
           [f isEqualToString:@"x-ebay-app-version"];
}

static NSString *EB107HeaderValue(NSString *field, NSString *value, NSURL *url) {
    if (![value isKindOfClass:[NSString class]]) return value;
    NSString *target = EB107VersionForURL(url);
    if (EB107IsVersionHeader(field)) return target;
    NSString *f = field.lowercaseString ?: @"";
    if ([f isEqualToString:@"user-agent"] || [f isEqualToString:@"x-ebay-mobile-app-info"]) {
        return EB107RewriteVersionText(value, target);
    }
    return value;
}

static NSDictionary *EB107Headers(NSDictionary *headers, NSURL *url) {
    if (![headers isKindOfClass:[NSDictionary class]] || !EB107IsEBayHost(url.host)) return headers;
    NSMutableDictionary *out = [headers mutableCopy];
    for (id rawKey in [out.allKeys copy]) {
        if (![rawKey isKindOfClass:[NSString class]]) continue;
        id rawValue = out[rawKey];
        if (![rawValue isKindOfClass:[NSString class]]) continue;
        out[rawKey] = EB107HeaderValue((NSString *)rawKey, (NSString *)rawValue, url);
    }
    out[@"X-EBAY-MOBILE-APP-VERSION"] = EB107VersionForURL(url);
    return out;
}

static NSURL *EB107URL(NSURL *url) {
    if (!url || !EB107IsEBayHost(url.host)) return url;
    NSString *target = EB107VersionForURL(url);
    NSString *original = url.absoluteString ?: @"";
    NSString *rewritten = EB107RewriteVersionText(original, target);

    if (EB107ItemV2Ready) {
        rewritten = [rewritten stringByReplacingOccurrencesOfString:@"/experience/listing_details/v1/view_item"
                                                         withString:@"/experience/listing_details/v2/view_item"];
        rewritten = [rewritten stringByReplacingOccurrencesOfString:@"/experience/listing_details/v1/module_provider"
                                                         withString:@"/experience/listing_details/v2/module_provider"];
        rewritten = [rewritten stringByReplacingOccurrencesOfString:@"/experience/listing_details/v1/preview_draft_listing"
                                                         withString:@"/experience/listing_details/v2/preview_draft_listing"];
    }

    if ([rewritten isEqualToString:original]) return url;
    return [NSURL URLWithString:rewritten] ?: url;
}

static NSData *EB107Body(NSData *body, NSURL *url) {
    if (!body || body.length == 0 || body.length > 2 * 1024 * 1024 || !EB107IsEBayHost(url.host)) return body;
    NSString *text = [[NSString alloc] initWithData:body encoding:NSUTF8StringEncoding];
    if (!text) return body;
    NSString *rewritten = EB107RewriteVersionText(text, EB107VersionForURL(url));
    if ([rewritten isEqualToString:text]) return body;
    return [rewritten dataUsingEncoding:NSUTF8StringEncoding] ?: body;
}

static NSString *EB107LogPath(void) {
    NSArray *paths = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
    NSString *dir = paths.firstObject ?: NSTemporaryDirectory();
    return [dir stringByAppendingPathComponent:@"eBayFixer.log"];
}

static void EB107Log(NSString *format, ...) {
    if (!format) return;
    va_list args;
    va_start(args, format);
    NSString *message = [[NSString alloc] initWithFormat:format arguments:args];
    va_end(args);
    if (!message) return;
    NSString *line = [NSString stringWithFormat:@"%@ %@\n", [NSDate date], message];
    NSData *data = [line dataUsingEncoding:NSUTF8StringEncoding];
    NSString *path = EB107LogPath();
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

static void EB107Prepare(NSMutableURLRequest *request) {
    if (!request || !EB107IsEBayHost(request.URL.host)) return;
    request.URL = EB107URL(request.URL);
    request.allHTTPHeaderFields = EB107Headers(request.allHTTPHeaderFields ?: @{}, request.URL);
    NSData *oldBody = request.HTTPBody;
    NSData *newBody = EB107Body(oldBody, request.URL);
    if (oldBody && newBody && ![oldBody isEqualToData:newBody]) {
        request.HTTPBody = newBody;
        [request setValue:[NSString stringWithFormat:@"%lu", (unsigned long)newBody.length]
       forHTTPHeaderField:@"Content-Length"];
    }
    if (EB107IsHomeURL(request.URL)) {
        EB107Log(@"HOME REQ %@ %@ version=%@ body=%lu",
                 request.HTTPMethod ?: @"GET",
                 request.URL.absoluteString ?: @"(nil)",
                 [request valueForHTTPHeaderField:@"X-EBAY-MOBILE-APP-VERSION"] ?: @"(none)",
                 (unsigned long)request.HTTPBody.length);
    }
}

static NSURLRequest *EB107PreparedRequest(NSURLRequest *request) {
    if (!request || !EB107IsEBayHost(request.URL.host)) return request;
    NSMutableURLRequest *copy = [request mutableCopy];
    if (!copy) return request;
    EB107Prepare(copy);
    return copy;
}

static BOOL EB107IsUpdateAlert(UIViewController *controller) {
    if (![controller isKindOfClass:[UIAlertController class]]) return NO;
    UIAlertController *alert = (UIAlertController *)controller;
    NSString *lower = [NSString stringWithFormat:@"%@ %@", alert.title ?: @"", alert.message ?: @""].lowercaseString;
    return [lower containsString:@"update required"] ||
           [lower containsString:@"version has expired"] ||
           [lower containsString:@"unsupported version"] ||
           [lower containsString:@"update ebay"] ||
           ([lower containsString:@"ebay"] && [lower containsString:@"update"] && [lower containsString:@"version"]);
}

static NSMutableSet *EB107InstalledHooks(void) {
    static NSMutableSet *set;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{ set = [NSMutableSet set]; });
    return set;
}

static BOOL EB107Yes(id self, SEL _cmd) { return YES; }

static BOOL EB107HookBool(Class cls, NSString *selectorName) {
    if (!cls || selectorName.length == 0) return NO;
    SEL selector = NSSelectorFromString(selectorName);
    if (!class_getInstanceMethod(cls, selector)) return NO;
    NSString *key = [NSString stringWithFormat:@"%@::%@", NSStringFromClass(cls), selectorName];
    @synchronized (EB107InstalledHooks()) {
        if ([EB107InstalledHooks() containsObject:key]) return YES;
        MSHookMessageEx(cls, selector, (IMP)EB107Yes, NULL);
        [EB107InstalledHooks() addObject:key];
    }
    return YES;
}

static void EB107InstallItemHooks(void) {
    NSArray *classes = @[
        @"_TtC11ItemProduct29ObjCItemProductFeatureToggles",
        @"ObjCItemProductFeatureToggles",
        @"_TtC11ItemProduct25ItemProductFeatureToggles",
        @"ItemProductFeatureToggles"
    ];
    BOOL found = NO;
    for (NSString *name in classes) {
        Class cls = NSClassFromString(name);
        found |= EB107HookBool(cls, @"useViewItemExperienceServiceRaptorIOURL");
        found |= EB107HookBool(cls, @"useViewItemExperienceServiceRaptorIOPreviewURL");
    }
    if (found) EB107ItemV2Ready = YES;
}

%hook NSBundle

- (id)objectForInfoDictionaryKey:(NSString *)key {
    if (self == [NSBundle mainBundle] && [key isEqualToString:@"CFBundleShortVersionString"]) {
        return EB107VisibleVersion;
    }
    return %orig;
}

- (NSDictionary *)infoDictionary {
    NSDictionary *dictionary = %orig;
    if (self != [NSBundle mainBundle] || !dictionary) return dictionary;
    NSMutableDictionary *copy = [dictionary mutableCopy];
    copy[@"CFBundleShortVersionString"] = EB107VisibleVersion;
    return copy;
}

- (NSDictionary *)localizedInfoDictionary {
    NSDictionary *dictionary = %orig;
    if (self != [NSBundle mainBundle] || !dictionary) return dictionary;
    NSMutableDictionary *copy = [dictionary mutableCopy];
    copy[@"CFBundleShortVersionString"] = EB107VisibleVersion;
    return copy;
}

%end

%hook UIViewController

- (void)presentViewController:(UIViewController *)controller animated:(BOOL)animated completion:(void (^)(void))completion {
    if (EB107IsUpdateAlert(controller)) {
        if (completion) completion();
        return;
    }
    %orig;
}

%end

%hook UIAlertView

- (void)show {
    NSString *lower = [NSString stringWithFormat:@"%@ %@", self.title ?: @"", self.message ?: @""].lowercaseString;
    if ([lower containsString:@"update required"] ||
        [lower containsString:@"version has expired"] ||
        [lower containsString:@"unsupported version"] ||
        [lower containsString:@"update ebay"]) {
        return;
    }
    %orig;
}

%end

%hook NSMutableURLRequest

- (void)setURL:(NSURL *)URL {
    NSURL *rewritten = EB107URL(URL);
    %orig(rewritten);
}

- (void)setValue:(NSString *)value forHTTPHeaderField:(NSString *)field {
    if (EB107IsEBayHost(self.URL.host)) {
        NSString *rewritten = EB107HeaderValue(field, value, self.URL);
        %orig(rewritten, field);
        return;
    }
    %orig;
}

- (void)addValue:(NSString *)value forHTTPHeaderField:(NSString *)field {
    if (EB107IsEBayHost(self.URL.host)) {
        NSString *rewritten = EB107HeaderValue(field, value, self.URL);
        %orig(rewritten, field);
        return;
    }
    %orig;
}

- (void)setAllHTTPHeaderFields:(NSDictionary *)headers {
    if (EB107IsEBayHost(self.URL.host)) {
        NSDictionary *rewritten = EB107Headers(headers, self.URL);
        %orig(rewritten);
        return;
    }
    %orig;
}

%end

%hook NSURLSessionConfiguration

- (void)setHTTPAdditionalHeaders:(NSDictionary *)headers {
    NSMutableDictionary *copy = [headers mutableCopy];
    for (id key in [copy.allKeys copy]) {
        if ([key isKindOfClass:[NSString class]] && [copy[key] isKindOfClass:[NSString class]]) {
            NSString *field = (NSString *)key;
            NSString *value = (NSString *)copy[key];
            if (EB107IsVersionHeader(field)) copy[key] = EB107VisibleVersion;
            else copy[key] = EB107RewriteVersionText(value, EB107VisibleVersion);
        }
    }
    %orig(copy ?: headers);
}

%end

%hook NSURLSession

- (NSURLSessionDataTask *)dataTaskWithRequest:(NSURLRequest *)request completionHandler:(void (^)(NSData *, NSURLResponse *, NSError *))handler {
    NSURLRequest *prepared = EB107PreparedRequest(request);
    BOOL home = EB107IsHomeURL(prepared.URL);
    void (^wrapped)(NSData *, NSURLResponse *, NSError *) = ^(NSData *data, NSURLResponse *response, NSError *error) {
        if (home) {
            NSInteger status = [response isKindOfClass:[NSHTTPURLResponse class]] ? [(NSHTTPURLResponse *)response statusCode] : 0;
            NSString *preview = @"";
            if (data.length > 0) {
                NSUInteger length = MIN((NSUInteger)1200, data.length);
                NSData *slice = [data subdataWithRange:NSMakeRange(0, length)];
                NSString *text = [[NSString alloc] initWithData:slice encoding:NSUTF8StringEncoding];
                if (text) preview = [text stringByReplacingOccurrencesOfString:@"\n" withString:@" "];
            }
            EB107Log(@"HOME RESP status=%ld bytes=%lu error=%@/%ld preview=%@",
                     (long)status, (unsigned long)data.length,
                     error.domain ?: @"none", (long)error.code, preview ?: @"");
        }
        if (handler) handler(data, response, error);
    };
    return %orig(prepared, wrapped);
}

- (NSURLSessionDataTask *)dataTaskWithRequest:(NSURLRequest *)request {
    NSURLRequest *prepared = EB107PreparedRequest(request);
    return %orig(prepared);
}

- (NSURLSessionUploadTask *)uploadTaskWithRequest:(NSURLRequest *)request fromData:(NSData *)data completionHandler:(void (^)(NSData *, NSURLResponse *, NSError *))handler {
    NSURLRequest *prepared = EB107PreparedRequest(request);
    NSData *body = EB107Body(data, prepared.URL);
    return %orig(prepared, body, handler);
}

%end

%ctor {
    @autoreleasepool {
        if (![[[NSBundle mainBundle] bundleIdentifier] isEqualToString:EB107BundleID]) return;
        [[NSFileManager defaultManager] removeItemAtPath:EB107LogPath() error:nil];
        %init;
        EB107InstallItemHooks();
        for (NSNumber *delay in @[@0.25, @1.0, @2.5, @5.0, @8.0]) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay.doubleValue * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{ EB107InstallItemHooks(); });
        }
    }
}
