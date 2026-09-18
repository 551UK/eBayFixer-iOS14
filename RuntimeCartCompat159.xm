#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <substrate.h>
#import "Prefs.h"

static id (*EB159OrigName)(id, SEL) = NULL;
static id (*EB159OrigParams)(id, SEL) = NULL;
static id (*EB159OrigMetadata)(id, SEL) = NULL;
static BOOL EB159Installed = NO;

static BOOL EB159IsAddToCartName(id value) {
    if (![value isKindOfClass:[NSString class]]) return NO;
    NSString *upper = [(NSString *)value uppercaseString];
    return [upper isEqualToString:@"VI_ADD_TO_CART"] ||
           [upper isEqualToString:@"ADD_TO_CART"];
}

static id EB159RawName(id self) {
    return EB159OrigName ? EB159OrigName(self, @selector(name)) : nil;
}

static id EB159Name(id self, SEL _cmd) {
    id value = EB159OrigName ? EB159OrigName(self, _cmd) : nil;
    if ([value isKindOfClass:[NSString class]] &&
        [[(NSString *)value uppercaseString] isEqualToString:@"VI_ADD_TO_CART"]) {
        // 6.96's generic response-action target understands ADD_TO_CART.
        // Current View Item responses use the newer VI_ADD_TO_CART namespace.
        // Translate at the parsed model getter so this also works when the
        // response bypasses NSJSONSerialization and is decoded directly.
        return @"ADD_TO_CART";
    }
    return value;
}

static id EB159Params(id self, SEL _cmd) {
    id original = EB159OrigParams ? EB159OrigParams(self, _cmd) : nil;
    if (!EB159IsAddToCartName(EB159RawName(self))) return original;

    NSMutableDictionary *out = [original isKindOfClass:[NSDictionary class]]
        ? [(NSDictionary *)original mutableCopy] : [NSMutableDictionary dictionary];

    // The old AddToCart model treats quantity as non-optional. Preserve any
    // value already supplied and only fill the missing legacy defaults.
    if (!out[@"quantity"]) out[@"quantity"] = @1;
    if (!out[@"quantityRequested"]) out[@"quantityRequested"] = @1;
    return out;
}

static id EB159Metadata(id self, SEL _cmd) {
    id original = EB159OrigMetadata ? EB159OrigMetadata(self, _cmd) : nil;
    if (!EB159IsAddToCartName(EB159RawName(self))) return original;

    NSMutableDictionary *out = [original isKindOfClass:[NSDictionary class]]
        ? [(NSDictionary *)original mutableCopy] : [NSMutableDictionary dictionary];
    if (!out[@"quantity"]) out[@"quantity"] = @1;
    if (!out[@"quantityRequested"]) out[@"quantityRequested"] = @1;
    return out;
}

static void EB159Install(void) {
    if (EB159Installed || !EBPrefsEnabled()) return;

    Class cls = objc_getClass("EBNResponseAction");
    if (!cls) return;

    Method nameMethod = class_getInstanceMethod(cls, @selector(name));
    if (!nameMethod) return;

    MSHookMessageEx(cls, @selector(name), (IMP)EB159Name, (IMP *)&EB159OrigName);

    Method paramsMethod = class_getInstanceMethod(cls, @selector(params));
    if (paramsMethod) {
        MSHookMessageEx(cls, @selector(params), (IMP)EB159Params, (IMP *)&EB159OrigParams);
    }

    Method metadataMethod = class_getInstanceMethod(cls, @selector(clientPresentationMetadata));
    if (metadataMethod) {
        MSHookMessageEx(cls, @selector(clientPresentationMetadata), (IMP)EB159Metadata, (IMP *)&EB159OrigMetadata);
    }

    EB159Installed = YES;
}

%ctor {
    @autoreleasepool {
        if (![[[NSBundle mainBundle] bundleIdentifier] isEqualToString:@"com.ebay.iphone"] ||
            !EBPrefsEnabled()) return;

        // EBNResponseAction lives in the Experience Service layer and can be
        // registered after our dylib constructor. Resolve only this exact class
        // and retry without enumerating the runtime.
        EB159Install();
        for (NSNumber *delay in @[@0.05, @0.15, @0.35, @0.75, @1.5, @3.0, @5.0]) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                                         (int64_t)(delay.doubleValue * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{
                EB159Install();
            });
        }
    }
}
