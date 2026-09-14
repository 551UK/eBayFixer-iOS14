#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

static NSString *const EBPublicVersion = @"6.273.0";
static NSString *const EBBackendVersion = @"6.192.0";
static NSString *const EBLegacyConfigVersion = @"6.96.0";

static BOOL EBIsEBayHost(NSString *host) {
    NSString *h = host.lowercaseString ?: @"";
    return [h containsString:@"ebay.com"] || [h containsString:@"ebaystatic.com"] || [h containsString:@"ebayimg.com"];
}

static BOOL EBIsDCSURL(NSURL *url) {
    NSString *h = url.host.lowercaseString ?: @"";
    NSString *p = url.path.lowercaseString ?: @"";
    return [h containsString:@"mobidcs"] || [p containsString:@"/mobile/dcs/"];
}

static NSString *EBIdentityForURL(NSURL *url) {
    return EBIsDCSURL(url) ? EBLegacyConfigVersion : EBBackendVersion;
}

static BOOL EBIsVersionHeader(NSString *field) {
    NSString *f = field.lowercaseString ?: @"";
    return [f isEqualToString:@"x-ebay-mobile-app-version"] ||
           [f isEqualToString:@"x-ebay-app-version"] ||
           [f containsString:@"client-version"] ||
           [f containsString:@"app-version"];
}

static NSString *EBRewriteIdentityText(NSString *value, NSURL *url) {
    if (![value isKindOfClass:[NSString class]]) return value;
    NSString *identity = EBIdentityForURL(url);
    NSString *out = value;
    for (NSString *old in @[EBPublicVersion, EBLegacyConfigVersion, @"6.267.0", @"6.272.0"]) {
        out = [out stringByReplacingOccurrencesOfString:old withString:identity];
    }
    return out;
}

static NSURL *EBRewriteURL(NSURL *url) {
    if (!url || !EBIsEBayHost(url.host)) return url;
    NSString *s = url.absoluteString ?: @"";
    NSString *before = s;
    s = [s stringByReplacingOccurrencesOfString:@"/experience/listing_details/v1/view_item" withString:@"/experience/listing_details/v2/view_item"];
    s = [s stringByReplacingOccurrencesOfString:@"/experience/listing_details/v1/module_provider" withString:@"/experience/listing_details/v2/module_provider"];
    s = [s stringByReplacingOccurrencesOfString:@"/experience/listing_details/v1/preview_draft_listing" withString:@"/experience/listing_details/v2/preview_draft_listing"];
    if (EBIsDCSURL(url) && ![s containsString:@"/version/1.0.0-seed/config"]) {
        NSError *error = nil;
        NSRegularExpression *re = [NSRegularExpression regularExpressionWithPattern:@"(/mobile/dcs/v1/app/[^/]+/version/)([^/?#]+)(/config)" options:NSRegularExpressionCaseInsensitive error:&error];
        if (re && !error) {
            s = [re stringByReplacingMatchesInString:s options:0 range:NSMakeRange(0, s.length) withTemplate:[NSString stringWithFormat:@"$1%@$3", EBLegacyConfigVersion]];
        }
    }
    if ([s isEqualToString:before]) return url;
    return [NSURL URLWithString:s] ?: url;
}

static NSDictionary *EBRewriteHeaders(NSDictionary *headers, NSURL *url) {
    if (![headers isKindOfClass:[NSDictionary class]] || !EBIsEBayHost(url.host)) return headers;
    NSMutableDictionary *out = [headers mutableCopy];
    for (id rawKey in [out.allKeys copy]) {
        if (![rawKey isKindOfClass:[NSString class]]) continue;
        NSString *key = (NSString *)rawKey;
        id rawValue = out[key];
        if (![rawValue isKindOfClass:[NSString class]]) continue;
        NSString *value = (NSString *)rawValue;
        if (EBIsVersionHeader(key)) out[key] = EBIdentityForURL(url);
        else if ([key caseInsensitiveCompare:@"User-Agent"] == NSOrderedSame || [key caseInsensitiveCompare:@"X-EBAY-MOBILE-APP-INFO"] == NSOrderedSame)
            out[key] = EBRewriteIdentityText(value, url);
    }
    return out;
}

static NSURLRequest *EBPrepareRequest(NSURLRequest *request) {
    if (!request || !EBIsEBayHost(request.URL.host)) return request;
    NSMutableURLRequest *m = [request mutableCopy];
    m.URL = EBRewriteURL(m.URL);
    m.allHTTPHeaderFields = EBRewriteHeaders(m.allHTTPHeaderFields ?: @{}, m.URL);
    return m;
}

static BOOL EBIsExpiryAlert(UIViewController *controller) {
    if (![controller isKindOfClass:[UIAlertController class]]) return NO;
    UIAlertController *a = (UIAlertController *)controller;
    NSString *text = [NSString stringWithFormat:@"%@ %@", a.title ?: @"", a.message ?: @""];
    return [text rangeOfString:@"update required" options:NSCaseInsensitiveSearch].location != NSNotFound ||
           [text rangeOfString:@"version has expired" options:NSCaseInsensitiveSearch].location != NSNotFound;
}

%hook NSBundle
- (id)objectForInfoDictionaryKey:(NSString *)key {
    if (self == [NSBundle mainBundle] && [key isEqualToString:@"CFBundleShortVersionString"]) return EBPublicVersion;
    return %orig;
}
- (NSDictionary *)infoDictionary {
    NSDictionary *d = %orig;
    if (self != [NSBundle mainBundle] || !d) return d;
    NSMutableDictionary *m = [d mutableCopy];
    m[@"CFBundleShortVersionString"] = EBPublicVersion;
    return m;
}
%end

%hook UIViewController
- (void)presentViewController:(UIViewController *)controller animated:(BOOL)animated completion:(void (^)(void))completion {
    if (EBIsExpiryAlert(controller)) {
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
        [text rangeOfString:@"version has expired" options:NSCaseInsensitiveSearch].location != NSNotFound) return;
    %orig;
}
%end

%hook NSMutableURLRequest
- (void)setURL:(NSURL *)URL { %orig(EBRewriteURL(URL)); }
- (void)setValue:(NSString *)value forHTTPHeaderField:(NSString *)field {
    if (EBIsEBayHost(self.URL.host)) {
        NSString *v = EBIsVersionHeader(field) ? EBIdentityForURL(self.URL) :
            (([field caseInsensitiveCompare:@"User-Agent"] == NSOrderedSame || [field caseInsensitiveCompare:@"X-EBAY-MOBILE-APP-INFO"] == NSOrderedSame) ? EBRewriteIdentityText(value, self.URL) : value);
        %orig(v, field);
        return;
    }
    %orig;
}
- (void)addValue:(NSString *)value forHTTPHeaderField:(NSString *)field {
    if (EBIsEBayHost(self.URL.host)) {
        NSString *v = EBIsVersionHeader(field) ? EBIdentityForURL(self.URL) :
            (([field caseInsensitiveCompare:@"User-Agent"] == NSOrderedSame || [field caseInsensitiveCompare:@"X-EBAY-MOBILE-APP-INFO"] == NSOrderedSame) ? EBRewriteIdentityText(value, self.URL) : value);
        %orig(v, field);
        return;
    }
    %orig;
}
- (void)setAllHTTPHeaderFields:(NSDictionary<NSString *,NSString *> *)headers { %orig(EBRewriteHeaders(headers, self.URL)); }
%end

%hook NSURLSession
- (NSURLSessionDataTask *)dataTaskWithRequest:(NSURLRequest *)request completionHandler:(void (^)(NSData *, NSURLResponse *, NSError *))completionHandler {
    return %orig(EBPrepareRequest(request), completionHandler);
}
- (NSURLSessionDataTask *)dataTaskWithRequest:(NSURLRequest *)request { return %orig(EBPrepareRequest(request)); }
- (NSURLSessionUploadTask *)uploadTaskWithRequest:(NSURLRequest *)request fromData:(NSData *)bodyData completionHandler:(void (^)(NSData *, NSURLResponse *, NSError *))completionHandler {
    return %orig(EBPrepareRequest(request), bodyData, completionHandler);
}
- (NSURLSessionDownloadTask *)downloadTaskWithRequest:(NSURLRequest *)request completionHandler:(void (^)(NSURL *, NSURLResponse *, NSError *))completionHandler {
    return %orig(EBPrepareRequest(request), completionHandler);
}
%end

%hook NSURLConnection
- (instancetype)initWithRequest:(NSURLRequest *)request delegate:(id)delegate startImmediately:(BOOL)startImmediately {
    return %orig(EBPrepareRequest(request), delegate, startImmediately);
}
+ (void)sendAsynchronousRequest:(NSURLRequest *)request queue:(NSOperationQueue *)queue completionHandler:(void (^)(NSURLResponse *, NSData *, NSError *))handler {
    %orig(EBPrepareRequest(request), queue, handler);
}
%end
