#import <Foundation/Foundation.h>

static BOOL EB111IsEBayURL(NSURL *url) {
    NSString *host = url.host.lowercaseString ?: @"";
    return [host isEqualToString:@"ebay.com"] || [host hasSuffix:@".ebay.com"] || [host hasSuffix:@".ebay.co.uk"];
}

static NSURL *EB111RewriteURL(NSURL *url) {
    if (!url || !EB111IsEBayURL(url)) return url;

    NSString *path = url.path ?: @"";
    NSString *newPath = nil;

    if ([path isEqualToString:@"/experience/shopping/v1/home"]) {
        newPath = @"/experience/vertical_landing/v1/get_homepage";
    } else if ([path isEqualToString:@"/experience/listing_details/v1/view_item"]) {
        newPath = @"/experience/listing_details/v2/view_item";
    } else if ([path isEqualToString:@"/experience/listing_details/v1/module_provider"]) {
        newPath = @"/experience/listing_details/v2/module_provider";
    } else if ([path isEqualToString:@"/experience/listing_details/v1/preview_draft_listing"]) {
        newPath = @"/experience/listing_details/v2/preview_draft_listing";
    }

    if (!newPath) return url;

    NSString *absolute = url.absoluteString ?: @"";
    NSRange range = [absolute rangeOfString:path];
    if (range.location == NSNotFound) return url;

    NSString *rewritten = [absolute stringByReplacingCharactersInRange:range withString:newPath];
    return [NSURL URLWithString:rewritten] ?: url;
}

static NSURLRequest *EB111RewriteRequest(NSURLRequest *request) {
    if (!request) return request;
    NSURL *newURL = EB111RewriteURL(request.URL);
    if (!newURL || [newURL isEqual:request.URL]) return request;

    NSMutableURLRequest *copy = [request mutableCopy];
    copy.URL = newURL;
    return copy ?: request;
}

%hook NSURLSession

- (NSURLSessionDataTask *)dataTaskWithRequest:(NSURLRequest *)request completionHandler:(void (^)(NSData *, NSURLResponse *, NSError *))handler {
    return %orig(EB111RewriteRequest(request), handler);
}

- (NSURLSessionDataTask *)dataTaskWithRequest:(NSURLRequest *)request {
    return %orig(EB111RewriteRequest(request));
}

- (NSURLSessionUploadTask *)uploadTaskWithRequest:(NSURLRequest *)request fromData:(NSData *)bodyData completionHandler:(void (^)(NSData *, NSURLResponse *, NSError *))handler {
    return %orig(EB111RewriteRequest(request), bodyData, handler);
}

%end

%ctor {
    if (![[[NSBundle mainBundle] bundleIdentifier] isEqualToString:@"com.ebay.iphone"]) return;
    %init;
}
