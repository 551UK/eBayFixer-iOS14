#import <Foundation/Foundation.h>

static NSString *const EB109Version = @"6.273.0";

static BOOL EB109IsHome(NSURL *url) {
    NSString *path = url.path.lowercaseString ?: @"";
    return [path containsString:@"/experience/shopping/v1/home"] ||
           [path containsString:@"/experience/shopping/v1/homepage/user_segmentation"] ||
           [path containsString:@"/experience/vertical_landing/v1/get_homepage"];
}

static NSURL *EB109Route(NSURL *url) {
    if (!url || !EB109IsHome(url)) return url;
    NSString *host = url.host.lowercaseString ?: @"";
    if (![host isEqualToString:@"apisd.ebay.com"] && ![host hasPrefix:@"apisd.ebay."]) return url;
    NSURLComponents *components = [NSURLComponents componentsWithURL:url resolvingAgainstBaseURL:NO];
    components.host = @"api.ebay.com";
    return components.URL ?: url;
}

static NSString *EB109Value(NSString *field, NSString *value) {
    if (![value isKindOfClass:[NSString class]]) return value;
    NSString *name = field.lowercaseString ?: @"";
    if ([name isEqualToString:@"x-ebay-mobile-app-version"] || [name isEqualToString:@"x-ebay-app-version"]) return EB109Version;
    if ([name isEqualToString:@"user-agent"] || [name isEqualToString:@"x-ebay-mobile-app-info"]) {
        NSString *out = value;
        for (NSString *old in @[@"6.96.0", @"6.192.0", @"6.267.0", @"6.272.0"]) {
            out = [out stringByReplacingOccurrencesOfString:old withString:EB109Version];
        }
        return out;
    }
    return value;
}

static NSMutableURLRequest *EB109Request(NSURLRequest *request) {
    NSMutableURLRequest *copy = [request mutableCopy];
    if (!copy) return nil;
    copy.URL = EB109Route(copy.URL);
    NSMutableDictionary *headers = [copy.allHTTPHeaderFields mutableCopy] ?: [NSMutableDictionary dictionary];
    for (id key in [headers.allKeys copy]) {
        if ([key isKindOfClass:[NSString class]] && [headers[key] isKindOfClass:[NSString class]]) {
            headers[key] = EB109Value((NSString *)key, (NSString *)headers[key]);
        }
    }
    headers[@"X-EBAY-MOBILE-APP-VERSION"] = EB109Version;
    copy.allHTTPHeaderFields = headers;
    return copy;
}

%hook NSMutableURLRequest

- (void)setURL:(NSURL *)URL {
    %orig(EB109Route(URL));
}

- (void)setValue:(NSString *)value forHTTPHeaderField:(NSString *)field {
    %orig(EB109Value(field, value), field);
}

- (void)addValue:(NSString *)value forHTTPHeaderField:(NSString *)field {
    %orig(EB109Value(field, value), field);
}

- (void)setAllHTTPHeaderFields:(NSDictionary *)headers {
    NSMutableDictionary *out = [headers mutableCopy] ?: [NSMutableDictionary dictionary];
    for (id key in [out.allKeys copy]) {
        if ([key isKindOfClass:[NSString class]] && [out[key] isKindOfClass:[NSString class]]) {
            out[key] = EB109Value((NSString *)key, (NSString *)out[key]);
        }
    }
    out[@"X-EBAY-MOBILE-APP-VERSION"] = EB109Version;
    %orig(out);
}

%end

%hook NSURLSession

- (NSURLSessionDataTask *)dataTaskWithRequest:(NSURLRequest *)request {
    NSMutableURLRequest *copy = EB109Request(request);
    return %orig(copy ?: request);
}

- (NSURLSessionDataTask *)dataTaskWithRequest:(NSURLRequest *)request completionHandler:(void (^)(NSData *, NSURLResponse *, NSError *))handler {
    NSMutableURLRequest *copy = EB109Request(request);
    return %orig(copy ?: request, handler);
}

%end

%ctor {
    if (![[[NSBundle mainBundle] bundleIdentifier] isEqualToString:@"com.ebay.iphone"]) return;
    %init;
}
