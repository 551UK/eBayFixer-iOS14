#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

static NSString *const EB110BundleID = @"com.ebay.iphone";
static NSString *const EB110Version = @"6.273.0";
static NSString *const EB110OriginalVersion = @"6.96.0";

static BOOL EB110IsEBayHost(NSString *host) {
    if (![host isKindOfClass:[NSString class]] || host.length == 0) return NO;
    NSString *h = host.lowercaseString;
    return [h isEqualToString:@"ebay.com"] || [h hasSuffix:@".ebay.com"] ||
           [h hasSuffix:@".ebay.co.uk"] || [h hasSuffix:@".ebaystatic.com"] ||
           [h hasSuffix:@".ebayimg.com"];
}

static NSString *EB110RewriteVersionText(NSString *value) {
    if (![value isKindOfClass:[NSString class]] || value.length == 0) return value;
    NSString *out = value;
    for (NSString *old in @[EB110OriginalVersion, @"6.192.0", @"6.267.0", @"6.272.0"]) {
        out = [out stringByReplacingOccurrencesOfString:old withString:EB110Version];
    }
    return out;
}

static BOOL EB110IsVersionHeader(NSString *field) {
    NSString *f = field.lowercaseString ?: @"";
    return [f isEqualToString:@"x-ebay-mobile-app-version"] ||
           [f isEqualToString:@"x-ebay-app-version"];
}

static NSString *EB110HeaderValue(NSString *field, NSString *value) {
    if (![value isKindOfClass:[NSString class]]) return value;
    if (EB110IsVersionHeader(field)) return EB110Version;
    NSString *f = field.lowercaseString ?: @"";
    if ([f isEqualToString:@"user-agent"] || [f isEqualToString:@"x-ebay-mobile-app-info"]) {
        return EB110RewriteVersionText(value);
    }
    return value;
}

static NSDictionary *EB110Headers(NSDictionary *headers, NSURL *url) {
    if (![headers isKindOfClass:[NSDictionary class]] || !EB110IsEBayHost(url.host)) return headers;
    NSMutableDictionary *out = [headers mutableCopy] ?: [NSMutableDictionary dictionary];
    for (id key in [out.allKeys copy]) {
        if (![key isKindOfClass:[NSString class]] || ![out[key] isKindOfClass:[NSString class]]) continue;
        out[key] = EB110HeaderValue((NSString *)key, (NSString *)out[key]);
    }
    out[@"X-EBAY-MOBILE-APP-VERSION"] = EB110Version;
    return out;
}

static NSData *EB110Body(NSData *body, NSURL *url) {
    if (!body || body.length == 0 || body.length > 2 * 1024 * 1024 || !EB110IsEBayHost(url.host)) return body;
    NSString *text = [[NSString alloc] initWithData:body encoding:NSUTF8StringEncoding];
    if (!text) return body;
    NSString *rewritten = EB110RewriteVersionText(text);
    if ([rewritten isEqualToString:text]) return body;
    return [rewritten dataUsingEncoding:NSUTF8StringEncoding] ?: body;
}

static void EB110Prepare(NSMutableURLRequest *request) {
    if (!request || !EB110IsEBayHost(request.URL.host)) return;
    request.allHTTPHeaderFields = EB110Headers(request.allHTTPHeaderFields ?: @{}, request.URL);
    NSData *oldBody = request.HTTPBody;
    NSData *newBody = EB110Body(oldBody, request.URL);
    if (oldBody && newBody && ![oldBody isEqualToData:newBody]) {
        request.HTTPBody = newBody;
        [request setValue:[NSString stringWithFormat:@"%lu", (unsigned long)newBody.length]
       forHTTPHeaderField:@"Content-Length"];
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
        %orig(EB110HeaderValue(field, value), field);
        return;
    }
    %orig;
}

- (void)addValue:(NSString *)value forHTTPHeaderField:(NSString *)field {
    if (EB110IsEBayHost(self.URL.host)) {
        %orig(EB110HeaderValue(field, value), field);
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
            copy[key] = EB110HeaderValue((NSString *)key, (NSString *)copy[key]);
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
