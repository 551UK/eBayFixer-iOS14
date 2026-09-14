#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <substrate.h>

static NSString *const EBTargetBundleID = @"com.ebay.iphone";
static NSString *const EBTargetVersion = @"6.273.0";
static NSString *const EBOriginalVersion = @"6.96.0";

#pragma mark - Focused diagnostic log

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
        if (!data) return;
        NSString *path = EBLogPath();
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
    });
}

#pragma mark - URL / version helpers

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
           [path containsString:@"view_item"] ||
           [path containsString:@"module_provider"];
}

static BOOL EBIsHomeURL(NSURL *url) {
    NSString *path = url.path.lowercaseString ?: @"";
    return [path containsString:@"/experience/shopping/v1/home"] ||
           [path containsString:@"vertical_landing"] ||
           [path containsString:@"bullseye"] ||
           [path containsString:@"homepage"];
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
    // Do not touch Apollo's apollographql-client-version. That identifies the
    // Apollo library, not the eBay application.
    return [f isEqualToString:@"x-ebay-mobile-app-version"] ||
           [f isEqualToString:@"x-ebay-app-version"];
}

static NSString *EBRewriteHeaderValue(NSString *field, NSString *value) {
    if (![value isKindOfClass:[NSString class]]) return value;
    if (EBIsAppVersionHeader(field)) return EBTargetVersion;

    NSString *f = field.lowercaseString ?: @"";
    if ([f isEqualToString:@"user-agent"] ||
        [f isEqualToString:@"x-ebay-mobile-app-info"]) {
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

    // IPA comparison: 6.96.0 contains both View Item v1 and v2; 6.192.0 no
    // longer contains the v1 listing-details endpoints. The feature-toggle hook
    // below selects 6.96.0's own v2 implementation. These replacements are only
    // a safety net in case a legacy request builder still emits v1.
    rewritten = [rewritten stringByReplacingOccurrencesOfString:@"/experience/listing_details/v1/view_item"
                                                     withString:@"/experience/listing_details/v2/view_item"];
    rewritten = [rewritten stringByReplacingOccurrencesOfString:@"/experience/listing_details/v1/module_provider"
                                                     withString:@"/experience/listing_details/v2/module_provider"];
    rewritten = [rewritten stringByReplacingOccurrencesOfString:@"/experience/listing_details/v1/preview_draft_listing"
                                                     withString:@"/experience/listing_details/v2/preview_draft_listing"];

    // IMPORTANT: never rewrite /mobile/dcs/.../version/1.0.0-seed/config.
    // 1.0.0-seed is eBay's DCS configuration/schema identifier, not the app
    // CFBundleShortVersionString. The previous experimental tweak changed it.

    if ([rewritten isEqualToString:original]) return url;
    NSURL *newURL = [NSURL URLWithString:rewritten];
    if (newURL && EBMarker(newURL)) EBLog(@"URL %@ -> %@", EBSafeURL(url), EBSafeURL(newURL));
    return newURL ?: url;
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

    NSDictionary *headers = EBRewriteHeaders(request.allHTTPHeaderFields ?: @{}, request.URL);
    if (headers) request.allHTTPHeaderFields = headers;

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
    NSMutableURLRequest *mutableRequest = [request mutableCopy];
    if (!mutableRequest) return request;
    EBPrepareMutableRequest(mutableRequest);
    return mutableRequest;
}

static void EBLogResponse(NSURLResponse *response, NSError *error, NSUInteger bytes, NSURL *fallbackURL) {
    NSURL *url = response.URL ?: fallbackURL;
    NSString *marker = EBMarker(url);
    if (!marker && !error) return;

    NSInteger status = [response isKindOfClass:[NSHTTPURLResponse class]] ?
        [(NSHTTPURLResponse *)response statusCode] : 0;
    EBLog(@"RESP %@ status=%ld bytes=%lu %@ error=%@/%ld %@",
          marker ?: @"NET", (long)status, (unsigned long)bytes,
          EBSafeURL(url), error.domain ?: @"none", (long)error.code,
          error.localizedDescription ?: @"");
}

#pragma mark - App identity / forced-update gate

static BOOL EBIsExpiryAlert(UIViewController *controller) {
    if (![controller isKindOfClass:[UIAlertController class]]) return NO;
    UIAlertController *alert = (UIAlertController *)controller;
    NSString *text = [NSString stringWithFormat:@"%@ %@", alert.title ?: @"", alert.message ?: @""];
    NSString *lower = text.lowercaseString;

    if ([lower containsString:@"update required"] ||
        [lower containsString:@"version has expired"] ||
        [lower containsString:@"unsupported version"] ||
        [lower containsString:@"update ebay"]) return YES;

    return [lower containsString:@"ebay"] &&
           [lower containsString:@"update"] &&
           ([lower containsString:@"version"] || [lower containsString:@"latest"]);
}

%hook NSBundle

- (id)objectForInfoDictionaryKey:(NSString *)key {
    if (self == [NSBundle mainBundle] && [key isEqualToString:@"CFBundleShortVersionString"]) {
        return EBTargetVersion;
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
        EBLog(@"Blocked eBay forced-update alert");
        if (completion) completion();
        return;
    }
    %orig;
}

%end

%hook UIAlertView

- (void)show {
    NSString *text = [NSString stringWithFormat:@"%@ %@", self.title ?: @"", self.message ?: @""];
    NSString *lower = text.lowercaseString;
    if ([lower containsString:@"update required"] ||
        [lower containsString:@"version has expired"] ||
        [lower containsString:@"unsupported version"] ||
        [lower containsString:@"update ebay"]) {
        EBLog(@"Blocked legacy eBay forced-update alert");
        return;
    }
    %orig;
}

%end

#pragma mark - Native feature paths found by comparing 6.96.0 and 6.192.0

// The relevant Swift frameworks may not be loaded at tweak initialization time.
// Hook them dynamically and retry after launch instead of relying on static Logos
// hooks silently resolving a nil class.

static NSMutableSet *EBInstalledFeatureHooks(void) {
    static NSMutableSet *set;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{ set = [NSMutableSet set]; });
    return set;
}

static BOOL EBForcedYES(id self, SEL _cmd) {
    return YES;
}

static BOOL EBForcedNO(id self, SEL _cmd) {
    return NO;
}

static BOOL EBHookBoolSelector(Class cls, NSString *selectorName, BOOL value) {
    if (!cls || selectorName.length == 0) return NO;
    SEL selector = NSSelectorFromString(selectorName);
    Method method = class_getInstanceMethod(cls, selector);
    if (!method) return NO;

    NSString *key = [NSString stringWithFormat:@"%@::%@", NSStringFromClass(cls), selectorName];
    @synchronized (EBInstalledFeatureHooks()) {
        if ([EBInstalledFeatureHooks() containsObject:key]) return YES;
        MSHookMessageEx(cls, selector, (IMP)(value ? EBForcedYES : EBForcedNO), NULL);
        [EBInstalledFeatureHooks() addObject:key];
    }
    EBLog(@"HOOK %@ %@ -> %@", NSStringFromClass(cls), selectorName, value ? @"YES" : @"NO");
    return YES;
}

static BOOL EBHookFirstMatchingClass(NSArray<NSString *> *classNames, NSString *selectorName, BOOL value) {
    BOOL found = NO;
    for (NSString *className in classNames) {
        Class cls = NSClassFromString(className);
        if (EBHookBoolSelector(cls, selectorName, value)) found = YES;
    }
    return found;
}

static void EBInstallNativeFeatureHooks(void) {
    // Home: old 6.96.0 has both the retired Bullseye path and eBay's newer
    // Vertical Landing Page flow. 6.192.0 retains homescreen.vlpF90 but no
    // longer contains the old Bullseye service URL. Force the newer native path.
    NSArray *homeClasses = @[
        @"_TtC14HomePageModule26ObjCHomePageFeatureToggles",
        @"ObjCHomePageFeatureToggles",
        @"_TtC14HomePageModule22HomePageFeatureToggles",
        @"HomePageFeatureToggles"
    ];
    BOOL home = NO;
    home |= EBHookFirstMatchingClass(homeClasses, @"vlpF90", YES);
    home |= EBHookFirstMatchingClass(homeClasses, @"vlpF90KillSwitch", NO);
    EBHookFirstMatchingClass(homeClasses, @"preprodServiceVLPHomepage", NO);
    EBHookFirstMatchingClass(homeClasses, @"preprodServiceVLPSegmentation", NO);

    // View Item: 6.96.0 contains v1 and v2 implementations. The 6.192.0 IPA
    // contains listing_details/v2 and no v1 endpoint. Force the old app to use
    // its own RaptorIO/VIES v2 implementation so response parsing matches v2.
    NSArray *itemClasses = @[
        @"_TtC11ItemProduct29ObjCItemProductFeatureToggles",
        @"ObjCItemProductFeatureToggles",
        @"_TtC11ItemProduct25ItemProductFeatureToggles",
        @"ItemProductFeatureToggles"
    ];
    BOOL item = NO;
    item |= EBHookFirstMatchingClass(itemClasses, @"useViewItemExperienceServiceRaptorIOURL", YES);
    item |= EBHookFirstMatchingClass(itemClasses, @"useViewItemExperienceServiceRaptorIOPreviewURL", YES);

    EBLog(@"Native feature scan home=%@ item=%@", home ? @"found" : @"not-yet-loaded", item ? @"found" : @"not-yet-loaded");
}

static void EBScheduleFeatureHookScans(void) {
    EBInstallNativeFeatureHooks();
    for (NSNumber *delayValue in @[@0.25, @1.0, @2.5, @5.0]) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delayValue.doubleValue * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            EBInstallNativeFeatureHooks();
        });
    }
}

%hook NSBundle

- (BOOL)load {
    BOOL result = %orig;
    if (result && self.bundlePath.length &&
        ([self.bundlePath containsString:@"HomePageModule.framework"] ||
         [self.bundlePath containsString:@"ItemProduct.framework"])) {
        EBLog(@"Loaded framework %@", self.bundlePath.lastPathComponent);
        EBInstallNativeFeatureHooks();
    }
    return result;
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

#pragma mark - Foundation networking send boundary

%hook NSURLSession

- (NSURLSessionDataTask *)dataTaskWithRequest:(NSURLRequest *)request completionHandler:(void (^)(NSData *, NSURLResponse *, NSError *))completionHandler {
    NSURLRequest *prepared = EBPrepareRequest(request);
    void (^wrapped)(NSData *, NSURLResponse *, NSError *) = ^(NSData *data, NSURLResponse *response, NSError *error) {
        EBLogResponse(response, error, data.length, prepared.URL);
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
        EBLogResponse(response, error, data.length, prepared.URL);
        if (completionHandler) completionHandler(data, response, error);
    };
    return %orig(prepared, body, wrapped);
}

%end

%ctor {
    @autoreleasepool {
        if (![[[NSBundle mainBundle] bundleIdentifier] isEqualToString:EBTargetBundleID]) return;
        EBLog(@"Loaded: real code 6.96.0, outward app version %@, iOS %@", EBTargetVersion, [UIDevice currentDevice].systemVersion);
        EBScheduleFeatureHookScans();
    }
}
