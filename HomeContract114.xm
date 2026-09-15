#import <Foundation/Foundation.h>

static NSString *const EB114HomePathOld = @"/experience/shopping/v1/home";
static NSString *const EB114HomePathNew = @"/experience/vertical_landing/v1/get_homepage";

// Reconstructed from eBay 6.96 HomePageModule's
// HomeVerticalLandingPageRequest.supportedUxComponents builder.
// MERCH_GRID exists in the static base list, but the same 6.96 build ships
// homescreen.verticalLandingPageExcludedUxComponentNames = ["MERCH_GRID"],
// so do not advertise it to the service here.
static NSString *EB114SupportedHomeComponents(void) {
    return @"ITEMS_CAROUSEL_V3,NAV_DESTINATIONS_CAROUSEL,TEXT_BANNER,FULL_BLEED_BANNER,MULTI_CTA_BANNER,ITEMS_CAROUSEL,ITEM_CARD_LIST,PAGE_TITLE,NAVIGATION_BAR,COLOR_BLOCK_BANNER,CARD_CONTAINERS_CAROUSEL_GROUP,ITEM_CARD_CAROUSEL";
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
    BOOL hasAudience = NO;

    for (NSURLQueryItem *item in components.queryItems ?: @[]) {
        NSString *name = item.name ?: @"";

        // Replace any old/manual supported-components contract with the exact
        // 6.96 VLP contract below.
        if ([name isEqualToString:@"supported_ux_components"] ||
            [name isEqualToString:@"supportedUxComponentNames"]) {
            continue;
        }

        if ([name isEqualToString:@"answersVersion"]) hasAnswersVersion = YES;
        if ([name isEqualToString:@"_pgn"]) hasPage = YES;

        // HomeVerticalLandingPageRequest adds audience=f90d when isF90User is
        // true. Our forced VLP route previously skipped the state that supplied
        // this flag, so normalize an existing audience value to the native F90
        // value and add it below when absent.
        if ([name isEqualToString:@"audience"]) {
            hasAudience = YES;
            [items addObject:[NSURLQueryItem queryItemWithName:@"audience" value:@"f90d"]];
            continue;
        }

        [items addObject:item];
    }

    if (!hasAnswersVersion) {
        [items addObject:[NSURLQueryItem queryItemWithName:@"answersVersion" value:@"1"]];
    }
    if (!hasPage) {
        [items addObject:[NSURLQueryItem queryItemWithName:@"_pgn" value:@"all"]];
    }
    if (!hasAudience) {
        [items addObject:[NSURLQueryItem queryItemWithName:@"audience" value:@"f90d"]];
    }

    [items addObject:[NSURLQueryItem queryItemWithName:@"supported_ux_components"
                                                 value:EB114SupportedHomeComponents()]];
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
