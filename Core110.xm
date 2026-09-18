#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import "Prefs.h"

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

static BOOL EB110IsDCSURL(NSURL *url) {
    if (!url) return NO;
    NSString *host = url.host.lowercaseString ?: @"";
    NSString *path = url.path.lowercaseString ?: @"";
    return [host isEqualToString:@"mobidcsng.ebay.com"] || [path containsString:@"/mobile/dcs/"];
}

static BOOL EB110IsShoppingCartURL(NSURL *url) {
    if (!url) return NO;
    NSString *path = url.path.lowercaseString ?: @"";
    return [path containsString:@"/experience/shopping_cart/"];
}

static NSString *EB110TargetVersionForURL(NSURL *url) {
    // The legacy 6.96 cart client still posts the old shopping-cart payload.
    // Keep that payload and its app-version headers internally consistent,
    // while retaining the newer spoof for the rest of eBay.
    return (EB110IsDCSURL(url) || EB110IsShoppingCartURL(url)) ? EB110OriginalVersion : EB110Version;
}

static NSString *EB110RewriteVersionTextForURL(NSString *value, NSURL *url) {
    if (![value isKindOfClass:[NSString class]] || value.length == 0) return value;
    NSString *target = EB110TargetVersionForURL(url);
    NSString *out = value;
    for (NSString *old in @[EB110OriginalVersion, EB110Version, @"6.192.0", @"6.267.0", @"6.272.0"])
        out = [out stringByReplacingOccurrencesOfString:old withString:target];
    return out;
}

static BOOL EB110IsVersionHeader(NSString *field) {
    NSString *f = field.lowercaseString ?: @"";
    return [f isEqualToString:@"x-ebay-mobile-app-version"] || [f isEqualToString:@"x-ebay-app-version"];
}

static NSString *EB110HeaderValue(NSString *field, NSString *value, NSURL *url) {
    if (![value isKindOfClass:[NSString class]]) return value;
    if (EB110IsVersionHeader(field)) return EB110TargetVersionForURL(url);
    NSString *f = field.lowercaseString ?: @"";
    if ([f isEqualToString:@"user-agent"] || [f isEqualToString:@"x-ebay-mobile-app-info"])
        return EB110RewriteVersionTextForURL(value, url);
    return value;
}

static NSDictionary *EB110Headers(NSDictionary *headers, NSURL *url) {
    if (![headers isKindOfClass:[NSDictionary class]] || !EB110IsEBayHost(url.host)) return headers;
    NSMutableDictionary *out = [headers mutableCopy] ?: [NSMutableDictionary dictionary];
    for (id key in [out.allKeys copy]) {
        if ([key isKindOfClass:[NSString class]] && [out[key] isKindOfClass:[NSString class]])
            out[key] = EB110HeaderValue(key, out[key], url);
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
    return [NSURL URLWithString:[absolute stringByReplacingOccurrencesOfString:needle withString:replacement]] ?: url;
}

static void EB110Prepare(NSMutableURLRequest *request) {
    if (!request || !EB110IsEBayHost(request.URL.host)) return;
    NSURL *compatURL = EB110DCSCompatURL(request.URL);
    if (compatURL && ![compatURL isEqual:request.URL]) request.URL = compatURL;
    request.allHTTPHeaderFields = EB110Headers(request.allHTTPHeaderFields ?: @{}, request.URL);
    NSData *newBody = EB110Body(request.HTTPBody, request.URL);
    if (request.HTTPBody && newBody && ![request.HTTPBody isEqualToData:newBody]) {
        request.HTTPBody = newBody;
        [request setValue:[NSString stringWithFormat:@"%lu", (unsigned long)newBody.length] forHTTPHeaderField:@"Content-Length"];
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
    return [lower containsString:@"update required"] || [lower containsString:@"version has expired"] ||
           [lower containsString:@"unsupported version"] || [lower containsString:@"update ebay"] ||
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
    if (EB110IsUpdateAlert(controller)) { if (completion) completion(); return; }
    %orig;
}
%end

%hook UIAlertView
- (void)show {
    NSString *lower = [NSString stringWithFormat:@"%@ %@", self.title ?: @"", self.message ?: @""].lowercaseString;
    if ([lower containsString:@"update required"] || [lower containsString:@"version has expired"] ||
        [lower containsString:@"unsupported version"] || [lower containsString:@"update ebay"]) return;
    %orig;
}
%end

%hook NSMutableURLRequest
- (void)setValue:(NSString *)value forHTTPHeaderField:(NSString *)field {
    if (EB110IsEBayHost(self.URL.host)) {
        NSString *rewritten = EB110HeaderValue(field, value, self.URL);
        %orig(rewritten, field);
        return;
    }
    %orig;
}
- (void)addValue:(NSString *)value forHTTPHeaderField:(NSString *)field {
    if (EB110IsEBayHost(self.URL.host)) {
        NSString *rewritten = EB110HeaderValue(field, value, self.URL);
        %orig(rewritten, field);
        return;
    }
    %orig;
}
- (void)setAllHTTPHeaderFields:(NSDictionary *)headers {
    if (EB110IsEBayHost(self.URL.host)) {
        NSDictionary *rewritten = EB110Headers(headers, self.URL);
        %orig(rewritten);
        return;
    }
    %orig;
}
%end

%hook NSURLSessionConfiguration
- (void)setHTTPAdditionalHeaders:(NSDictionary *)headers {
    NSMutableDictionary *copy = [headers mutableCopy] ?: [NSMutableDictionary dictionary];
    for (id key in [copy.allKeys copy]) {
        if ([key isKindOfClass:[NSString class]] && [copy[key] isKindOfClass:[NSString class]])
            copy[key] = EB110HeaderValue(key, copy[key], nil);
    }
    copy[@"X-EBAY-MOBILE-APP-VERSION"] = EB110Version;
    %orig(copy);
}
%end

%hook NSURLSession
- (NSURLSessionDataTask *)dataTaskWithRequest:(NSURLRequest *)request completionHandler:(void (^)(NSData *, NSURLResponse *, NSError *))handler {
    NSURLRequest *prepared = EB110PreparedRequest(request);
    return %orig(prepared, handler);
}
- (NSURLSessionDataTask *)dataTaskWithRequest:(NSURLRequest *)request {
    NSURLRequest *prepared = EB110PreparedRequest(request);
    return %orig(prepared);
}
- (NSURLSessionUploadTask *)uploadTaskWithRequest:(NSURLRequest *)request fromData:(NSData *)data completionHandler:(void (^)(NSData *, NSURLResponse *, NSError *))handler {
    NSURLRequest *prepared = EB110PreparedRequest(request);
    NSData *rewrittenBody = EB110Body(data, prepared.URL);
    return %orig(prepared, rewrittenBody, handler);
}
%end

%ctor {
    @autoreleasepool {
        if (![[[NSBundle mainBundle] bundleIdentifier] isEqualToString:EB110BundleID] || !EBPrefsEnabled()) return;
        %init;
    }
}
