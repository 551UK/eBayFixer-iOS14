#import <Foundation/Foundation.h>

static NSString *const EB114HomePathOld = @"/experience/shopping/v1/home";
static NSString *const EB114HomePathNew = @"/experience/vertical_landing/v1/get_homepage";

static NSString *EB114SupportedHomeComponents(void) {
    return @"NAVIGATION_IMAGE_GRID,ITEMS_CAROUSEL,ITEM_CARD_LIST,PAGE_TITLE,MERCH_GRID,NAVIGATION_BAR,COLD_START_TOP_OF_PAGE,TOP_OF_PAGE_WITH_VEHICLE,RECOMMENDED_ACTIONS,CARD_CONTAINERS_CAROUSEL_GROUP,ITEM_CARD_CAROUSEL,USER_GARAGE_MODULE";
}

static BOOL EB114IsEBayHost(NSString *host) {
    NSString *h = host.lowercaseString ?: @"";
    return [h isEqualToString:@"ebay.com"] || [h hasSuffix:@".ebay.com"] || [h hasSuffix:@".ebay.co.uk"];
}

static NSURL *EB114NormalizeHomeURL(NSURL *url) {
    if (!url || !EB114IsEBayHost(url.host)) return url;
    NSString *path = url.path ?: @"";
    if (![path isEqualToString:EB114HomePathOld] && ![path isEqualToString:EB114HomePathNew]) return url;

    NSURLComponents *components = [NSURLComponents componentsWithURL:url resolvingAgainstBaseURL:NO];
    if (!components) return url;
    components.path = EB114HomePathNew;

    NSMutableArray<NSURLQueryItem *> *items = [NSMutableArray array];
    BOOL hasAnswersVersion = NO;
    BOOL hasPage = NO;
    for (NSURLQueryItem *item in components.queryItems ?: @[]) {
        NSString *name = item.name ?: @"";
        if ([name isEqualToString:@"supported_ux_components"] || [name isEqualToString:@"supportedUxComponentNames"]) continue;
        if ([name isEqualToString:@"answersVersion"]) hasAnswersVersion = YES;
        if ([name isEqualToString:@"_pgn"]) hasPage = YES;
        [items addObject:item];
    }
    if (!hasAnswersVersion) [items addObject:[NSURLQueryItem queryItemWithName:@"answersVersion" value:@"1"]];
    if (!hasPage) [items addObject:[NSURLQueryItem queryItemWithName:@"_pgn" value:@"all"]];
    [items addObject:[NSURLQueryItem queryItemWithName:@"supported_ux_components" value:EB114SupportedHomeComponents()]];
    components.queryItems = items;
    return components.URL ?: url;
}

static NSURLRequest *EB114NormalizeHomeRequest(NSURLRequest *request) {
    if (!request) return request;
    NSURL *normalized = EB114NormalizeHomeURL(request.URL);
    if (!normalized || [normalized isEqual:request.URL]) return request;
    NSMutableURLRequest *copy = [request mutableCopy];
    copy.URL = normalized;
    return copy ?: request;
}

%hook NSMutableURLRequest
- (void)setURL:(NSURL *)URL {
    %orig(EB114NormalizeHomeURL(URL));
}
%end

%hook NSURLSession
- (NSURLSessionDataTask *)dataTaskWithRequest:(NSURLRequest *)request completionHandler:(void (^)(NSData *, NSURLResponse *, NSError *))handler {
    return %orig(EB114NormalizeHomeRequest(request), handler);
}
- (NSURLSessionDataTask *)dataTaskWithRequest:(NSURLRequest *)request {
    return %orig(EB114NormalizeHomeRequest(request));
}
- (NSURLSessionUploadTask *)uploadTaskWithRequest:(NSURLRequest *)request fromData:(NSData *)bodyData completionHandler:(void (^)(NSData *, NSURLResponse *, NSError *))handler {
    return %orig(EB114NormalizeHomeRequest(request), bodyData, handler);
}
%end

%ctor {
    if (![[[NSBundle mainBundle] bundleIdentifier] isEqualToString:@"com.ebay.iphone"]) return;
    %init;
}
