#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

static NSString *const EB110BundleID = @"com.ebay.iphone";
static NSString *const EB110Version = @"6.273.0";
static NSString *const EB110OriginalVersion = @"6.96.0";

static NSString *EB110LogPath(void) {
    NSArray *paths = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
    NSString *dir = paths.firstObject ?: NSTemporaryDirectory();
    return [dir stringByAppendingPathComponent:@"eBayFixer.log"];
}

static void EB110Log(NSString *format, ...) {
    if (!format) return;
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

static BOOL EB110IsEBayHost(NSString *host) {
    if (![host isKindOfClass:[NSString class]] || host.length == 0) return NO;
    NSString *h = host.lowercaseString;
    return [h isEqualToString:@"ebay.com"] || [h hasSuffix:@".ebay.com"] ||
           [h hasSuffix:@".ebay.co.uk"] || [h hasSuffix:@".ebaystatic.com"] ||
           [h hasSuffix:@".ebayimg.com"];
}

static BOOL EB110IsDCSURL(NSURL *url) {
    if (!url) return NO;
    NSString *host = url.host.lowercaseString ?: @"";
    NSString *path = url.path.lowercaseString ?: @"";
    return [host isEqualToString:@"mobidcsng.ebay.com"] || [path containsString:@"/mobile/dcs/"];
}

static BOOL EB110IsHomeVLPURL(NSURL *url) {
    if (!url) return NO;
    NSString *host = url.host.lowercaseString ?: @"";
    NSString *path = url.path.lowercaseString ?: @"";
    BOOL ebayHost = [host isEqualToString:@"ebay.com"] || [host hasSuffix:@".ebay.com"] || [host hasSuffix:@".ebay.co.uk"];
    if (!ebayHost) return NO;
    return [path isEqualToString:@"/experience/vertical_landing/v1/get_homepage"] ||
           [path isEqualToString:@"/experience/shopping/v1/home"];
}

static BOOL EB110UseOriginalVersionForURL(NSURL *url) {
    return EB110IsDCSURL(url) || EB110IsHomeVLPURL(url);
}

static NSString *EB110TargetVersionForURL(NSURL *url) {
    return EB110UseOriginalVersionForURL(url) ? EB110OriginalVersion : EB110Version;
}

static NSString *EB110RewriteVersionTextForURL(NSString *value, NSURL *url) {
    if (![value isKindOfClass:[NSString class]] || value.length == 0) return value;
    NSString *target = EB110TargetVersionForURL(url);
    NSString *out = value;
    for (NSString *old in @[EB110OriginalVersion, EB110Version, @"6.192.0", @"6.267.0", @"6.272.0"]) {
        out = [out stringByReplacingOccurrencesOfString:old withString:target];
    }
    return out;
}

static BOOL EB110IsVersionHeader(NSString *field) {
    NSString *f = field.lowercaseString ?: @"";
    return [f isEqualToString:@"x-ebay-mobile-app-version"] ||
           [f isEqualToString:@"x-ebay-app-version"];
}

static NSString *EB110HeaderValue(NSString *field, NSString *value, NSURL *url) {
    if (![value isKindOfClass:[NSString class]]) return value;
    if (EB110IsVersionHeader(field)) return EB110TargetVersionForURL(url);
    NSString *f = field.lowercaseString ?: @"";
    if ([f isEqualToString:@"user-agent"] || [f isEqualToString:@"x-ebay-mobile-app-info"]) {
        return EB110RewriteVersionTextForURL(value, url);
    }
    return value;
}

static NSDictionary *EB110Headers(NSDictionary *headers, NSURL *url) {
    if (![headers isKindOfClass:[NSDictionary class]] || !EB110IsEBayHost(url.host)) return headers;
    NSMutableDictionary *out = [headers mutableCopy] ?: [NSMutableDictionary dictionary];
    for (id key in [out.allKeys copy]) {
        if (![key isKindOfClass:[NSString class]] || ![out[key] isKindOfClass:[NSString class]]) continue;
        out[key] = EB110HeaderValue((NSString *)key, (NSString *)out[key], url);
    }
    out[@"X-EBAY-MOBILE-APP-VERSION"] = EB110TargetVersionForURL(url);
    return out;
}

static NSData *EB110Body(NSData *body, NSURL *url) {
    if (!body || body.length == 0 || body.length > 2 * 1024 * 1024 || !EB110IsEBayHost(url.host)) return body;
    NSString *text = [[NSString alloc] initWithData:body encoding:NSUTF8StringEncoding];
    if (!text) return body;
    NSString *rewritten = EB110RewriteVersionTextForURL(text, url);
    if ([rewritten isEqualToString:text]) return body;
    return [rewritten dataUsingEncoding:NSUTF8StringEncoding] ?: body;
}

static NSURL *EB110DCSCompatURL(NSURL *url) {
    if (!EB110IsDCSURL(url)) return url;
    NSString *absolute = url.absoluteString ?: @"";
    NSString *needle = [NSString stringWithFormat:@"/version/%@/", EB110Version];
    if (![absolute containsString:needle]) return url;
    NSString *replacement = [NSString stringWithFormat:@"/version/%@/", EB110OriginalVersion];
    NSString *rewritten = [absolute stringByReplacingOccurrencesOfString:needle withString:replacement];
    NSURL *newURL = [NSURL URLWithString:rewritten];
    if (newURL) {
        EB110Log(@"DCS_COMPAT url_version %@ -> %@", EB110Version, EB110OriginalVersion);
        return newURL;
    }
    return url;
}

static void EB110Prepare(NSMutableURLRequest *request) {
    if (!request || !EB110IsEBayHost(request.URL.host)) return;

    NSURL *compatURL = EB110DCSCompatURL(request.URL);
    if (compatURL && ![compatURL isEqual:request.URL]) request.URL = compatURL;

    request.allHTTPHeaderFields = EB110Headers(request.allHTTPHeaderFields ?: @{}, request.URL);
    NSData *oldBody = request.HTTPBody;
    NSData *newBody = EB110Body(oldBody, request.URL);
    if (oldBody && newBody && ![oldBody isEqualToData:newBody]) {
        request.HTTPBody = newBody;
        [request setValue:[NSString stringWithFormat:@"%lu", (unsigned long)newBody.length]
       forHTTPHeaderField:@"Content-Length"];
    }

    if (EB110IsDCSURL(request.URL)) {
        EB110Log(@"DCS_COMPAT prepared version=%@ url=%@", EB110OriginalVersion, request.URL.absoluteString ?: @"-");
    } else if (EB110IsHomeVLPURL(request.URL)) {
        EB110Log(@"HOME_VERSION141 prepared version=%@ url=%@", EB110OriginalVersion, request.URL.absoluteString ?: @"-");
    }
}

static NSURLRequest *EB110PreparedRequest(NSURLRequest *request) {
    if (!request || !EB110IsEBayHost(request.URL.host)) return request;
    NSMutableURLRequest *copy = [request mutableCopy];
    if (!copy) return request;
    EB110Prepare(copy);
    return copy;
}

static BOOL EB110IsUpdateAlert(UIViewController *controller) {
    if (![controller isKindOfClass:[UIAlertController class]]) return NO;
    UIAlertController *alert = (UIAlertController *)controller;
    NSString *lower = [NSString stringWithFormat:@"%@ %@", alert.title ?: @"", alert.message ?: @""].lowercaseString;
    return [lower containsString:@"update required"] ||
           [lower containsString:@"version has expired"] ||
           [lower containsString:@"unsupported version"] ||
           [lower containsString:@"update ebay"] ||
           ([lower containsString:@"ebay"] && [lower containsString:@"update"] && [lower containsString:@"version"]);
}

%hook NSBundle

- (id)objectForInfoDictionaryKey:(NSString *)key {
    if (self == [NSBundle mainBundle] && [key isEqualToString:@"CFBundleShortVersionString"]) return EB110Version;
    return %orig;
}

- (NSDictionary *)infoDictionary {
    NSDictionary *dictionary = %orig;
    if (self != [NSBundle mainBundle] || !dictionary) return dictionary;
    NSMutableDictionary *copy = [dictionary mutableCopy];
    copy[@"CFBundleShortVersionString"] = EB110Version;
    return copy;
}

- (NSDictionary *)localizedInfoDictionary {
    NSDictionary *dictionary = %orig;
    if (self != [NSBundle mainBundle] || !dictionary) return dictionary;
    NSMutableDictionary *copy = [dictionary mutableCopy];
    copy[@"CFBundleShortVersionString"] = EB110Version;
    return copy;
}

%end

%hook UIViewController

- (void)presentViewController:(UIViewController *)controller animated:(BOOL)animated completion:(void (^)(void))completion {
    if (EB110IsUpdateAlert(controller)) {
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
        [lower containsString:@"update ebay"]) return;
    %orig;
}

%end

%hook NSMutableURLRequest

- (void)setValue:(NSString *)value forHTTPHeaderField:(NSString *)field {
    if (EB110IsEBayHost(self.URL.host)) {
        %orig(EB110HeaderValue(field, value, self.URL), field);
        return;
    }
    %orig;
}

- (void)addValue:(NSString *)value forHTTPHeaderField:(NSString *)field {
    if (EB110IsEBayHost(self.URL.host)) {
        %orig(EB110HeaderValue(field, value, self.URL), field);
        return;
    }
    %orig;
}

- (void)setAllHTTPHeaderFields:(NSDictionary *)headers {
    if (EB110IsEBayHost(self.URL.host)) {
        %orig(EB110Headers(headers, self.URL));
        return;
    }
    %orig;
}

%end

%hook NSURLSessionConfiguration

- (void)setHTTPAdditionalHeaders:(NSDictionary *)headers {
    NSMutableDictionary *copy = [headers mutableCopy] ?: [NSMutableDictionary dictionary];
    for (id key in [copy.allKeys copy]) {
        if ([key isKindOfClass:[NSString class]] && [copy[key] isKindOfClass:[NSString class]]) {
            copy[key] = EB110HeaderValue((NSString *)key, (NSString *)copy[key], nil);
        }
    }
    copy[@"X-EBAY-MOBILE-APP-VERSION"] = EB110Version;
    %orig(copy);
}

%end

%hook NSURLSession

- (NSURLSessionDataTask *)dataTaskWithRequest:(NSURLRequest *)request completionHandler:(void (^)(NSData *, NSURLResponse *, NSError *))handler {
    return %orig(EB110PreparedRequest(request), handler);
}

- (NSURLSessionDataTask *)dataTaskWithRequest:(NSURLRequest *)request {
    return %orig(EB110PreparedRequest(request));
}

- (NSURLSessionUploadTask *)uploadTaskWithRequest:(NSURLRequest *)request fromData:(NSData *)data completionHandler:(void (^)(NSData *, NSURLResponse *, NSError *))handler {
    NSURLRequest *prepared = EB110PreparedRequest(request);
    return %orig(prepared, EB110Body(data, prepared.URL), handler);
}

%end

%ctor {
    @autoreleasepool {
        if (![[[NSBundle mainBundle] bundleIdentifier] isEqualToString:EB110BundleID]) return;
        %init;
    }
}
