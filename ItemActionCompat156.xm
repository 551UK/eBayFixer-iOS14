#import <Foundation/Foundation.h>
#import "Prefs.h"

static BOOL EB156IsAddToCartName(id value) {
    if (![value isKindOfClass:[NSString class]]) return NO;
    NSString *name = [(NSString *)value uppercaseString];
    return [name isEqualToString:@"VI_ADD_TO_CART"] || [name isEqualToString:@"ADD_TO_CART"];
}

static id EB156ItemIDFromAction(NSDictionary *action) {
    if (![action isKindOfClass:[NSDictionary class]]) return nil;

    NSDictionary *params = [action[@"params"] isKindOfClass:[NSDictionary class]] ? action[@"params"] : nil;
    id itemID = params[@"itemId"] ?: params[@"listingId"];
    if (itemID) return itemID;

    NSDictionary *metadata = [action[@"clientPresentationMetadata"] isKindOfClass:[NSDictionary class]]
        ? action[@"clientPresentationMetadata"] : nil;
    return metadata[@"itemId"] ?: metadata[@"listingId"];
}

static id EB156ItemIDFromButtons(NSArray *buttons) {
    for (id rawButton in buttons) {
        if (![rawButton isKindOfClass:[NSDictionary class]]) continue;
        NSDictionary *button = (NSDictionary *)rawButton;
        NSDictionary *action = [button[@"action"] isKindOfClass:[NSDictionary class]] ? button[@"action"] : nil;
        id itemID = EB156ItemIDFromAction(action);
        if (itemID) return itemID;
    }
    return nil;
}

static NSDictionary *EB156PatchBuyBoxModule(NSDictionary *module, BOOL *changedOut) {
    if (changedOut) *changedOut = NO;
    if (![module isKindOfClass:[NSDictionary class]]) return module;

    NSArray *buttons = [module[@"buttons"] isKindOfClass:[NSArray class]] ? module[@"buttons"] : nil;
    if (!buttons.count) return module;

    id siblingItemID = EB156ItemIDFromButtons(buttons);
    if (!siblingItemID) return module;

    NSMutableArray *patchedButtons = [buttons mutableCopy];
    BOOL changed = NO;

    for (NSUInteger i = 0; i < patchedButtons.count; i++) {
        id rawButton = patchedButtons[i];
        if (![rawButton isKindOfClass:[NSDictionary class]]) continue;

        NSDictionary *button = (NSDictionary *)rawButton;
        NSDictionary *action = [button[@"action"] isKindOfClass:[NSDictionary class]] ? button[@"action"] : nil;
        if (!action) continue;

        BOOL isAdd = EB156IsAddToCartName(button[@"actionId"]) ||
                     EB156IsAddToCartName(action[@"name"]);
        if (!isAdd) continue;

        NSMutableDictionary *patchedAction = [action mutableCopy];

        // Current View Item responses provide the listing id on sibling actions
        // (for example VIEW_IN_CART) but omit it from VI_ADD_TO_CART. eBay 6.96's
        // native operation dispatcher predates that contract and expects the
        // listing identity on the operation itself.
        NSMutableDictionary *params = [action[@"params"] isKindOfClass:[NSDictionary class]]
            ? [action[@"params"] mutableCopy] : [NSMutableDictionary dictionary];
        if (!params[@"itemId"]) params[@"itemId"] = siblingItemID;
        if (!params[@"listingId"]) params[@"listingId"] = siblingItemID;
        patchedAction[@"params"] = params;

        NSMutableDictionary *metadata = [action[@"clientPresentationMetadata"] isKindOfClass:[NSDictionary class]]
            ? [action[@"clientPresentationMetadata"] mutableCopy] : [NSMutableDictionary dictionary];
        if (!metadata[@"itemId"]) metadata[@"itemId"] = siblingItemID;
        patchedAction[@"clientPresentationMetadata"] = metadata;

        NSMutableDictionary *patchedButton = [button mutableCopy];
        patchedButton[@"action"] = patchedAction;
        patchedButtons[i] = patchedButton;
        changed = YES;
    }

    if (!changed) return module;

    NSMutableDictionary *patchedModule = [module mutableCopy];
    patchedModule[@"buttons"] = patchedButtons;
    if (changedOut) *changedOut = YES;
    return patchedModule;
}

static id EB156PatchItemResponse(id object) {
    if (![object isKindOfClass:[NSDictionary class]]) return object;

    NSDictionary *root = (NSDictionary *)object;
    NSDictionary *modules = [root[@"modules"] isKindOfClass:[NSDictionary class]] ? root[@"modules"] : nil;
    if (!modules.count) return object;

    NSMutableDictionary *patchedModules = nil;
    BOOL changed = NO;

    for (id key in modules) {
        id rawModule = modules[key];
        if (![rawModule isKindOfClass:[NSDictionary class]]) continue;

        NSDictionary *module = (NSDictionary *)rawModule;
        NSString *type = [module[@"_type"] isKindOfClass:[NSString class]] ? module[@"_type"] : @"";
        BOOL looksLikeBuyBox = [key isKindOfClass:[NSString class]] &&
                               ([(NSString *)key isEqualToString:@"BUY_BOX_CTA"] ||
                                [(NSString *)key containsString:@"BUY_BOX"]);
        looksLikeBuyBox = looksLikeBuyBox || [type isEqualToString:@"BuyBoxActionModule"];
        if (!looksLikeBuyBox) continue;

        BOOL moduleChanged = NO;
        NSDictionary *patched = EB156PatchBuyBoxModule(module, &moduleChanged);
        if (!moduleChanged) continue;

        if (!patchedModules) patchedModules = [modules mutableCopy];
        patchedModules[key] = patched;
        changed = YES;
    }

    if (!changed) return object;

    NSMutableDictionary *patchedRoot = [root mutableCopy];
    patchedRoot[@"modules"] = patchedModules;
    return patchedRoot;
}

%hook NSJSONSerialization

+ (id)JSONObjectWithData:(NSData *)data options:(NSJSONReadingOptions)opt error:(NSError **)error {
    id object = %orig;
    if (!EBPrefsEnabled()) return object;
    return EB156PatchItemResponse(object);
}

%end

%ctor {
    @autoreleasepool {
        if (![[[NSBundle mainBundle] bundleIdentifier] isEqualToString:@"com.ebay.iphone"] || !EBPrefsEnabled()) return;
        %init;
    }
}
