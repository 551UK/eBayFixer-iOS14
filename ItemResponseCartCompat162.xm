#import <Foundation/Foundation.h>
#import "Prefs.h"

static BOOL EB162IsViewItemResponseURL(NSURL *url) {
    if (!url) return NO;
    NSString *path = url.path.lowercaseString ?: @"";
    return [path containsString:@"/experience/listing_details/v2/view_item"] ||
           [path containsString:@"/experience/listing_details/v2/module_provider"];
}

static NSString *EB162StringID(id value) {
    if ([value isKindOfClass:[NSString class]] && [(NSString *)value length]) return value;
    if ([value isKindOfClass:[NSNumber class]]) return [(NSNumber *)value stringValue];
    return nil;
}

static NSString *EB162ItemIDFromURL(NSURL *url) {
    NSURLComponents *components = [NSURLComponents componentsWithURL:url resolvingAgainstBaseURL:NO];
    for (NSURLQueryItem *item in components.queryItems ?: @[]) {
        if ([item.name isEqualToString:@"itemId"] ||
            [item.name isEqualToString:@"item_id"] ||
            [item.name isEqualToString:@"listingID"] ||
            [item.name isEqualToString:@"listingId"]) {
            if (item.value.length) return item.value;
        }
    }
    return nil;
}

static BOOL EB162IsAddButton(NSDictionary *button) {
    if (![button isKindOfClass:[NSDictionary class]]) return NO;
    NSDictionary *action = [button[@"action"] isKindOfClass:[NSDictionary class]] ? button[@"action"] : nil;
    NSString *actionID = [button[@"actionId"] isKindOfClass:[NSString class]] ? button[@"actionId"] : @"";
    NSString *name = [action[@"name"] isKindOfClass:[NSString class]] ? action[@"name"] : @"";
    return [actionID caseInsensitiveCompare:@"VI_ADD_TO_CART"] == NSOrderedSame ||
           [name caseInsensitiveCompare:@"VI_ADD_TO_CART"] == NSOrderedSame ||
           [name caseInsensitiveCompare:@"ADD_TO_CART"] == NSOrderedSame;
}

static NSString *EB162FindSiblingItemID(NSArray *buttons) {
    for (id raw in buttons) {
        if (![raw isKindOfClass:[NSDictionary class]]) continue;
        NSDictionary *button = raw;
        NSDictionary *action = [button[@"action"] isKindOfClass:[NSDictionary class]] ? button[@"action"] : nil;
        if (!action) continue;

        NSDictionary *params = [action[@"params"] isKindOfClass:[NSDictionary class]] ? action[@"params"] : nil;
        NSString *itemID = EB162StringID(params[@"listingID"]) ?:
                           EB162StringID(params[@"listingId"]) ?:
                           EB162StringID(params[@"itemId"]);
        if (itemID.length) return itemID;

        NSDictionary *meta = [action[@"clientPresentationMetadata"] isKindOfClass:[NSDictionary class]]
            ? action[@"clientPresentationMetadata"] : nil;
        itemID = EB162StringID(meta[@"listingID"]) ?:
                 EB162StringID(meta[@"listingId"]) ?:
                 EB162StringID(meta[@"itemId"]);
        if (itemID.length) return itemID;
    }
    return nil;
}

static BOOL EB162PatchBuyBoxModule(NSMutableDictionary *module, NSString *fallbackItemID) {
    NSArray *buttons = [module[@"buttons"] isKindOfClass:[NSArray class]] ? module[@"buttons"] : nil;
    if (!buttons.count) return NO;

    NSString *itemID = EB162FindSiblingItemID(buttons) ?: fallbackItemID;
    if (!itemID.length) return NO;

    NSMutableArray *patchedButtons = [buttons mutableCopy];
    BOOL changed = NO;

    for (NSUInteger i = 0; i < patchedButtons.count; i++) {
        id raw = patchedButtons[i];
        if (![raw isKindOfClass:[NSDictionary class]]) continue;
        NSDictionary *button = raw;
        if (!EB162IsAddButton(button)) continue;

        NSDictionary *action = [button[@"action"] isKindOfClass:[NSDictionary class]] ? button[@"action"] : nil;
        if (!action) continue;

        NSMutableDictionary *patchedAction = [action mutableCopy];

        // PaymentsModule's native cart interpreter expects exactly
        // action.params.listingID. Current View Item responses omit params
        // completely for VI_ADD_TO_CART, so the old client has nothing to add.
        NSMutableDictionary *params = [action[@"params"] isKindOfClass:[NSDictionary class]]
            ? [action[@"params"] mutableCopy] : [NSMutableDictionary dictionary];

        if (!params[@"listingID"]) params[@"listingID"] = itemID;
        if (!params[@"listingId"]) params[@"listingId"] = itemID;
        if (!params[@"itemId"]) params[@"itemId"] = itemID;
        if (!params[@"quantity"]) params[@"quantity"] = @1;
        if (!params[@"quantityRequested"]) params[@"quantityRequested"] = @1;
        patchedAction[@"params"] = params;

        NSMutableDictionary *metadata = [action[@"clientPresentationMetadata"] isKindOfClass:[NSDictionary class]]
            ? [action[@"clientPresentationMetadata"] mutableCopy] : [NSMutableDictionary dictionary];
        if (!metadata[@"listingID"]) metadata[@"listingID"] = itemID;
        if (!metadata[@"listingId"]) metadata[@"listingId"] = itemID;
        if (!metadata[@"itemId"]) metadata[@"itemId"] = itemID;
        if (!metadata[@"quantity"]) metadata[@"quantity"] = @1;
        if (!metadata[@"quantityRequested"]) metadata[@"quantityRequested"] = @1;
        patchedAction[@"clientPresentationMetadata"] = metadata;

        NSMutableDictionary *patchedButton = [button mutableCopy];
        patchedButton[@"action"] = patchedAction;
        patchedButtons[i] = patchedButton;
        changed = YES;
    }

    if (changed) module[@"buttons"] = patchedButtons;
    return changed;
}

static NSData *EB162PatchResponseData(NSData *data, NSURL *url) {
    if (!data.length || !EB162IsViewItemResponseURL(url)) return data;

    NSError *error = nil;
    id rootObj = [NSJSONSerialization JSONObjectWithData:data
                                                options:NSJSONReadingMutableContainers
                                                  error:&error];
    if (error || ![rootObj isKindOfClass:[NSMutableDictionary class]]) return data;

    NSMutableDictionary *root = rootObj;
    NSMutableDictionary *modules = [root[@"modules"] isKindOfClass:[NSDictionary class]]
        ? [root[@"modules"] mutableCopy] : nil;
    if (!modules.count) return data;

    NSString *fallbackItemID = EB162ItemIDFromURL(url);
    BOOL changed = NO;

    for (id key in [modules.allKeys copy]) {
        id rawModule = modules[key];
        if (![rawModule isKindOfClass:[NSDictionary class]]) continue;

        NSDictionary *module = rawModule;
        NSString *type = [module[@"_type"] isKindOfClass:[NSString class]] ? module[@"_type"] : @"";
        BOOL buyBox = ([key isKindOfClass:[NSString class]] &&
                       ([(NSString *)key isEqualToString:@"BUY_BOX_CTA"] ||
                        [(NSString *)key containsString:@"BUY_BOX"])) ||
                      [type isEqualToString:@"BuyBoxActionModule"];
        if (!buyBox) continue;

        NSMutableDictionary *patchedModule = [module mutableCopy];
        if (EB162PatchBuyBoxModule(patchedModule, fallbackItemID)) {
            modules[key] = patchedModule;
            changed = YES;
        }
    }

    if (!changed) return data;
    root[@"modules"] = modules;

    NSData *patched = [NSJSONSerialization dataWithJSONObject:root options:0 error:&error];
    return (!error && patched.length) ? patched : data;
}

%hook NSURLSession

- (NSURLSessionDataTask *)dataTaskWithRequest:(NSURLRequest *)request
                            completionHandler:(void (^)(NSData *, NSURLResponse *, NSError *))handler {
    if (!EBPrefsEnabled() || !EB162IsViewItemResponseURL(request.URL) || !handler) {
        return %orig;
    }

    void (^wrapped)(NSData *, NSURLResponse *, NSError *) = ^(NSData *data, NSURLResponse *response, NSError *error) {
        NSData *patched = error ? data : EB162PatchResponseData(data, response.URL ?: request.URL);
        handler(patched, response, error);
    };
    return %orig(request, wrapped);
}

- (NSURLSessionDataTask *)dataTaskWithURL:(NSURL *)url
                       completionHandler:(void (^)(NSData *, NSURLResponse *, NSError *))handler {
    if (!EBPrefsEnabled() || !EB162IsViewItemResponseURL(url) || !handler) {
        return %orig;
    }

    void (^wrapped)(NSData *, NSURLResponse *, NSError *) = ^(NSData *data, NSURLResponse *response, NSError *error) {
        NSData *patched = error ? data : EB162PatchResponseData(data, response.URL ?: url);
        handler(patched, response, error);
    };
    return %orig(url, wrapped);
}

%end

%ctor {
    @autoreleasepool {
        if (![[[NSBundle mainBundle] bundleIdentifier] isEqualToString:@"com.ebay.iphone"] ||
            !EBPrefsEnabled()) return;
        %init;
    }
}
