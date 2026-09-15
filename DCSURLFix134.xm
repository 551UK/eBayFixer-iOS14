#import <Foundation/Foundation.h>

static NSString *const EB134SpoofVersion = @"6.273.0";
static NSString *const EB134RealVersion = @"6.96.0";

static BOOL EB134IsDCS(NSURL *url) {
    if (!url) return NO;
    NSString *host = url.host.lowercaseString ?: @"";
    NSString *path = url.path.lowercaseString ?: @"";
    return [host isEqualToString:@"mobidcsng.ebay.com"] && [path containsString:@"/mobile/dcs/"];
}

static NSURL *EB134RewriteDCSURL(NSURL *url) {
    if (!EB134IsDCS(url)) return url;
    NSString *absolute = url.absoluteString ?: @"";
    NSString *needle = [NSString stringWithFormat:@"/version/%@/", EB134SpoofVersion];
    if (![absolute containsString:needle]) return url;
    NSString *replacement = [NSString stringWithFormat:@"/version/%@/", EB134RealVersion];
    NSURL *rewritten = [NSURL URLWithString:[absolute stringByReplacingOccurrencesOfString:needle withString:replacement]];
    return rewritten ?: url;
}

%hook NSMutableURLRequest

- (void)setURL:(NSURL *)URL {
    %orig(EB134RewriteDCSURL(URL));
}

%end

%hook NSURLSession

- (NSURLSessionDataTask *)dataTaskWithURL:(NSURL *)url {
    return %orig(EB134RewriteDCSURL(url));
}

- (NSURLSessionDataTask *)dataTaskWithURL:(NSURL *)url completionHandler:(void (^)(NSData *, NSURLResponse *, NSError *))completionHandler {
    return %orig(EB134RewriteDCSURL(url), completionHandler);
}

- (NSURLSessionDownloadTask *)downloadTaskWithURL:(NSURL *)url {
    return %orig(EB134RewriteDCSURL(url));
}

- (NSURLSessionDownloadTask *)downloadTaskWithURL:(NSURL *)url completionHandler:(void (^)(NSURL *, NSURLResponse *, NSError *))completionHandler {
    return %orig(EB134RewriteDCSURL(url), completionHandler);
}

%end

%ctor {
    if (![[[NSBundle mainBundle] bundleIdentifier] isEqualToString:@"com.ebay.iphone"]) return;
    %init;
}
