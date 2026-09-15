#import <Foundation/Foundation.h>
#import "Prefs.h"

static BOOL EB111IsEBayURL(NSURL *url) {
    NSString *host = url.host.lowercaseString ?: @"";
    return [host isEqualToString:@"ebay.com"] || [host hasSuffix:@".ebay.com"] || [host hasSuffix:@".ebay.co.uk"];
}

static NSURL *EB111RewriteURL(NSURL *url) {
    if (!url || !EB111IsEBayURL(url)) return url;

    NSURLComponents *components = [NSURLComponents componentsWithURL:url resolvingAgainstBaseURL:NO];
    if (!components) return url;

    NSString *path = components.path ?: @"";
    if ([path isEqualToString:@"/experience/listing_details/v1/view_item"]) {
        components.path = @"/experience/listing_details/v2/view_item";
    } else if ([path isEqualToString:@"/experience/listing_details/v1/module_provider"]) {
        components.path = @"/experience/listing_details/v2/module_provider";
    } else if ([path isEqualToString:@"/experience/listing_details/v1/preview_draft_listing"]) {
        components.path = @"/experience/listing_details/v2/preview_draft_listing";
    }

    NSString *newPath = components.path ?: @"";
    if (![newPath containsString:@"/experience/listing_details/v2/"]) return components.URL ?: url;

    NSMutableArray<NSURLQueryItem *> *items = [components.queryItems mutableCopy] ?: [NSMutableArray array];
    NSString *itemID = nil;
    NSString *variationID = nil;
    BOOL hasItemIDAlias = NO;
    BOOL hasVariationIDAlias = NO;

    for (NSURLQueryItem *item in items) {
        if ([item.name isEqualToString:@"item_id"] && item.value.length) itemID = item.value;
        if ([item.name isEqualToString:@"variation_id"] && item.value.length) variationID = item.value;
        if ([item.name isEqualToString:@"itemId"]) hasItemIDAlias = YES;
        if ([item.name isEqualToString:@"variationId"]) hasVariationIDAlias = YES;
    }

    if (itemID.length && !hasItemIDAlias) [items addObject:[NSURLQueryItem queryItemWithName:@"itemId" value:itemID]];
    if (variationID.length && !hasVariationIDAlias) [items addObject:[NSURLQueryItem queryItemWithName:@"variationId" value:variationID]];
    components.queryItems = items;
    return components.URL ?: url;
}

static NSURLRequest *EB111RewriteRequest(NSURLRequest *request) {
    if (!request) return request;
    NSURL *newURL = EB111RewriteURL(request.URL);
    if (!newURL || [newURL isEqual:request.URL]) return request;
    NSMutableURLRequest *copy = [request mutableCopy];
    copy.URL = newURL;
    return copy ?: request;
}

%hook NSMutableURLRequest
- (void)setURL:(NSURL *)URL { %orig(EB111RewriteURL(URL)); }
%end

%hook NSURLSession
- (NSURLSessionDataTask *)dataTaskWithRequest:(NSURLRequest *)request completionHandler:(void (^)(NSData *, NSURLResponse *, NSError *))handler { return %orig(EB111RewriteRequest(request), handler); }
- (NSURLSessionDataTask *)dataTaskWithRequest:(NSURLRequest *)request { return %orig(EB111RewriteRequest(request)); }
- (NSURLSessionUploadTask *)uploadTaskWithRequest:(NSURLRequest *)request fromData:(NSData *)bodyData completionHandler:(void (^)(NSData *, NSURLResponse *, NSError *))handler { return %orig(EB111RewriteRequest(request), bodyData, handler); }
%end

%ctor {
    if (![[[NSBundle mainBundle] bundleIdentifier] isEqualToString:@"com.ebay.iphone"] || !EBPrefsEnabled()) return;
    %init;
}
