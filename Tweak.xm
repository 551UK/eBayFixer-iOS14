#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <substrate.h>

static NSString *const EBTargetBundleID = @"com.ebay.iphone";
static NSString *const EBTargetVersion = @"6.273.0";
static NSString *const EBOriginalVersion = @"6.96.0";
static BOOL EBItemV2Ready = NO;

static BOOL EBIsEBayHost(NSString *host) {
    if (![host isKindOfClass:[NSString class]] || host.length == 0) return NO;
    NSString *h = host.lowercaseString;
    return [h isEqualToString:@"ebay.com"] || [h hasSuffix:@".ebay.com"] ||
           [h hasSuffix:@".ebay.co.uk"] || [h hasSuffix:@".ebaystatic.com"] ||
           [h hasSuffix:@".ebayimg.com"];
}

static BOOL EBIsEBayBundle(NSBundle *bundle) {
    NSString *path = bundle.bundlePath ?: @"";
    if ([path hasSuffix:@"/eBay.app"]) return YES;
    return [path rangeOfString:@"/eBay.app/" options:NSCaseInsensitiveSearch].location != NSNotFound;
}

static NSString *EBRewriteVersion(NSString *value) {
    if (![value isKindOfClass:[NSString class]] || value.length == 0) return value;
    NSString *out = value;
    for (NSString *old in @[EBOriginalVersion, @"6.267.0", @"6.272.0"]) {
        out = [out stringByReplacingOccurrencesOfString:old withString:EBTargetVersion];
    }
    return out;
}

static BOOL EBIsVersionHeader(NSString *field) {
    NSString *f = field.lowercaseString ?: @"";
    return [f isEqualToString:@"x-ebay-mobile-app-version"] ||
           [f isEqualToString:@"x-ebay-app-version"];
}

static NSString *EBHeaderValue(NSString *field, NSString *value) {
    if (![value isKindOfClass:[NSString class]]) return value;
    if (EBIsVersionHeader(field)) return EBTargetVersion;
    NSString *f = field.lowercaseString ?: @"";
    if ([f isEqualToString:@"user-agent"] || [f isEqualToString:@"x-ebay-mobile-app-info"]) {
        return EBRewriteVersion(value);
    }
    return value;
}

static NSDictionary *EBHeaders(NSDictionary *headers, NSURL *url) {
    if (![headers isKindOfClass:[NSDictionary class]] || !EBIsEBayHost(url.host)) return headers;
    NSMutableDictionary *out = [headers mutableCopy];
    for (id rawKey in [out.allKeys copy]) {
        if (![rawKey isKindOfClass:[NSString class]]) continue;
        id rawValue = out[rawKey];
        if (![rawValue isKindOfClass:[NSString class]]) continue;
        out[rawKey] = EBHeaderValue((NSString *)rawKey, (NSString *)rawValue);
    }
    out[@"X-EBAY-MOBILE-APP-VERSION"] = EBTargetVersion;
    return out;
}

static NSURL *EBURL(NSURL *url) {
    if (!url || !EBIsEBayHost(url.host)) return url;
    NSString *original = url.absoluteString ?: @"";
    NSString *rewritten = EBRewriteVersion(original);
    if (EBItemV2Ready) {
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

static NSData *EBBody(NSData *body, NSURL *url) {
    if (!body || body.length == 0 || body.length > 2 * 1024 * 1024 || !EBIsEBayHost(url.host)) return body;
    NSString *text = [[NSString alloc] initWithData:body encoding:NSUTF8StringEncoding];
    if (!text) return body;
    NSString *rewritten = EBRewriteVersion(text);
    if ([rewritten isEqualToString:text]) return body;
    return [rewritten dataUsingEncoding:NSUTF8StringEncoding] ?: body;
}

static void EBPrepare(NSMutableURLRequest *request) {
    if (!request || !EBIsEBayHost(request.URL.host)) return;
    request.URL = EBURL(request.URL);
    request.allHTTPHeaderFields = EBHeaders(request.allHTTPHeaderFields ?: @{}, request.URL);
    NSData *oldBody = request.HTTPBody;
    NSData *newBody = EBBody(oldBody, request.URL);
    if (oldBody && newBody && ![oldBody isEqualToData:newBody]) {
        request.HTTPBody = newBody;
        [request setValue:[NSString stringWithFormat:@"%lu", (unsigned long)newBody.length]
       forHTTPHeaderField:@"Content-Length"];
    }
}

static NSURLRequest *EBPreparedRequest(NSURLRequest *request) {
    if (!request || !EBIsEBayHost(request.URL.host)) return request;
    NSMutableURLRequest *copy = [request mutableCopy];
    if (!copy) return request;
    EBPrepare(copy);
    return copy;
}

static BOOL EBIsUpdateAlert(UIViewController *controller) {
    if (![controller isKindOfClass:[UIAlertController class]]) return NO;
    UIAlertController *alert = (UIAlertController *)controller;
    NSString *lower = [NSString stringWithFormat:@"%@ %@", alert.title ?: @"", alert.message ?: @""].lowercaseString;
    return [lower containsString:@"update required"] ||
           [lower containsString:@"version has expired"] ||
           [lower containsString:@"unsupported version"] ||
           [lower containsString:@"update ebay"] ||
           ([lower containsString:@"ebay"] && [lower containsString:@"update"] && [lower containsString:@"version"]);
}

static NSMutableSet *EBInstalledHooks(void) {
    static NSMutableSet *set;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{ set = [NSMutableSet set]; });
    return set;
}

static BOOL EBYes(id self, SEL _cmd) { return YES; }
static BOOL EBNo(id self, SEL _cmd) { return NO; }

static BOOL EBHookBool(Class cls, NSString *selectorName, BOOL value) {
    if (!cls) return NO;
    SEL selector = NSSelectorFromString(selectorName);
    if (!class_getInstanceMethod(cls, selector)) return NO;
    NSString *key = [NSString stringWithFormat:@"%@::%@", NSStringFromClass(cls), selectorName];
    @synchronized (EBInstalledHooks()) {
        if ([EBInstalledHooks() containsObject:key]) return YES;
        MSHookMessageEx(cls, selector, (IMP)(value ? EBYes : EBNo), NULL);
        [EBInstalledHooks() addObject:key];
    }
    return YES;
}

static BOOL EBHookClasses(NSArray *names, NSString *selector, BOOL value) {
    BOOL found = NO;
    for (NSString *name in names) if (EBHookBool(NSClassFromString(name), selector, value)) found = YES;
    return found;
}

static void EBInstallNativeHooks(void) {
    NSArray *home = @[
        @"_TtC14HomePageModule26ObjCHomePageFeatureToggles",
        @"ObjCHomePageFeatureToggles",
        @"_TtC14HomePageModule22HomePageFeatureToggles",
        @"HomePageFeatureToggles"
    ];
    EBHookClasses(home, @"vlpF90", YES);
    EBHookClasses(home, @"vlpF90KillSwitch", NO);
    EBHookClasses(home, @"preprodServiceVLPHomepage", NO);
    EBHookClasses(home, @"preprodServiceVLPSegmentation", NO);

    NSArray *item = @[
        @"_TtC11ItemProduct29ObjCItemProductFeatureToggles",
        @"ObjCItemProductFeatureToggles",
        @"_TtC11ItemProduct25ItemProductFeatureToggles",
        @"ItemProductFeatureToggles"
    ];
    BOOL found = EBHookClasses(item, @"useViewItemExperienceServiceRaptorIOURL", YES);
    found |= EBHookClasses(item, @"useViewItemExperienceServiceRaptorIOPreviewURL", YES);
    if (found) EBItemV2Ready = YES;
}

static void EBScheduleNativeHooks(void) {
    EBInstallNativeHooks();
    for (NSNumber *delay in @[@0.25, @1.0, @2.5, @5.0]) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay.doubleValue * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{ EBInstallNativeHooks(); });
    }
}

%hook NSBundle
- (id)objectForInfoDictionaryKey:(NSString *)key {
    if (EBIsEBayBundle(self) && [key isEqualToString:@"CFBundleShortVersionString"]) return EBTargetVersion;
    return %orig;
}
- (NSDictionary *)infoDictionary {
    NSDictionary *dictionary = %orig;
    if (!EBIsEBayBundle(self) || !dictionary) return dictionary;
    NSMutableDictionary *copy = [dictionary mutableCopy];
    copy[@"CFBundleShortVersionString"] = EBTargetVersion;
    return copy;
}
- (NSDictionary *)localizedInfoDictionary {
    NSDictionary *dictionary = %orig;
    if (!EBIsEBayBundle(self) || !dictionary) return dictionary;
    NSMutableDictionary *copy = [dictionary mutableCopy];
    copy[@"CFBundleShortVersionString"] = EBTargetVersion;
    return copy;
}
- (BOOL)load {
    BOOL result = %orig;
    if (result && ([self.bundlePath containsString:@"HomePageModule.framework"] ||
                   [self.bundlePath containsString:@"ItemProduct.framework"])) EBInstallNativeHooks();
    return result;
}
%end

%hook UIViewController
- (void)presentViewController:(UIViewController *)controller animated:(BOOL)animated completion:(void (^)(void))completion {
    if (EBIsUpdateAlert(controller)) { if (completion) completion(); return; }
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
- (void)setURL:(NSURL *)URL { %orig(EBURL(URL)); }
- (void)setValue:(NSString *)value forHTTPHeaderField:(NSString *)field {
    if (EBIsEBayHost(self.URL.host)) { %orig(EBHeaderValue(field, value), field); return; }
    %orig;
}
- (void)addValue:(NSString *)value forHTTPHeaderField:(NSString *)field {
    if (EBIsEBayHost(self.URL.host)) { %orig(EBHeaderValue(field, value), field); return; }
    %orig;
}
- (void)setAllHTTPHeaderFields:(NSDictionary *)headers {
    if (EBIsEBayHost(self.URL.host)) { %orig(EBHeaders(headers, self.URL)); return; }
    %orig;
}
%end

%hook NSURLSessionConfiguration
- (void)setHTTPAdditionalHeaders:(NSDictionary *)headers {
    NSMutableDictionary *copy = [headers mutableCopy];
    for (id key in [copy.allKeys copy]) {
        if ([key isKindOfClass:[NSString class]] && [copy[key] isKindOfClass:[NSString class]])
            copy[key] = EBHeaderValue((NSString *)key, (NSString *)copy[key]);
    }
    %orig(copy ?: headers);
}
%end

%hook NSURLSession
- (NSURLSessionDataTask *)dataTaskWithRequest:(NSURLRequest *)request completionHandler:(void (^)(NSData *, NSURLResponse *, NSError *))handler {
    return %orig(EBPreparedRequest(request), handler);
}
- (NSURLSessionDataTask *)dataTaskWithRequest:(NSURLRequest *)request { return %orig(EBPreparedRequest(request)); }
- (NSURLSessionUploadTask *)uploadTaskWithRequest:(NSURLRequest *)request fromData:(NSData *)data completionHandler:(void (^)(NSData *, NSURLResponse *, NSError *))handler {
    NSURLRequest *prepared = EBPreparedRequest(request);
    return %orig(prepared, EBBody(data, prepared.URL), handler);
}
%end

%ctor {
    @autoreleasepool {
        if (![[[NSBundle mainBundle] bundleIdentifier] isEqualToString:EBTargetBundleID]) return;
        %init;
        EBScheduleNativeHooks();
    }
}
