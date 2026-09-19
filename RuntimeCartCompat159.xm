#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <substrate.h>
#import "Prefs.h"

static id (*EB159OrigName)(id, SEL) = NULL;
static id (*EB159OrigParams)(id, SEL) = NULL;
static id (*EB159OrigMetadata)(id, SEL) = NULL;
static void (*EB159OrigSetName)(id, SEL, id) = NULL;
static void (*EB159OrigSetParams)(id, SEL, id) = NULL;
static void (*EB159OrigSetMetadata)(id, SEL, id) = NULL;
static BOOL EB159Installed = NO;

static NSString *EB159RecentBuyBoxItemID = nil;

static NSObject *EB159CacheLock(void) {
    static NSObject *lock;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{ lock = [NSObject new]; });
    return lock;
}

static BOOL EB159IsAddToCartName(id value) {
    if (![value isKindOfClass:[NSString class]]) return NO;
    NSString *upper = [(NSString *)value uppercaseString];
    return [upper isEqualToString:@"VI_ADD_TO_CART"] ||
           [upper isEqualToString:@"ADD_TO_CART"];
}

static BOOL EB159IsBuyBoxSiblingName(id value) {
    if (![value isKindOfClass:[NSString class]]) return NO;
    NSString *upper = [(NSString *)value uppercaseString];
    return [upper isEqualToString:@"VI_VIEW_IN_CART"] ||
           [upper isEqualToString:@"VIEW_IN_CART"] ||
           [upper isEqualToString:@"WATCH"] ||
           [upper isEqualToString:@"UNWATCH"];
}

static NSString *EB159StringItemID(id value) {
    if ([value isKindOfClass:[NSString class]] && [(NSString *)value length]) {
        return (NSString *)value;
    }
    if ([value isKindOfClass:[NSNumber class]]) {
        return [(NSNumber *)value stringValue];
    }
    return nil;
}

static NSString *EB159ItemIDFromDictionary(id value) {
    if (![value isKindOfClass:[NSDictionary class]]) return nil;
    NSDictionary *dict = (NSDictionary *)value;
    return EB159StringItemID(dict[@"itemId"]) ?: EB159StringItemID(dict[@"listingId"]);
}

static void EB159RememberItemID(NSString *itemID) {
    if (!itemID.length) return;
    @synchronized (EB159CacheLock()) {
        EB159RecentBuyBoxItemID = [itemID copy];
    }
}

static NSString *EB159RememberedItemID(void) {
    @synchronized (EB159CacheLock()) {
        return [EB159RecentBuyBoxItemID copy];
    }
}

static id EB159RawName(id self) {
    return EB159OrigName ? EB159OrigName(self, @selector(name)) : nil;
}

static void EB159HarvestSibling(id self, id dictionary) {
    id name = EB159RawName(self);
    if (!EB159IsBuyBoxSiblingName(name)) return;
    EB159RememberItemID(EB159ItemIDFromDictionary(dictionary));
}

static void EB159FillLegacyCartFields(NSMutableDictionary *out) {
    if (!out) return;

    NSString *itemID = EB159RememberedItemID();
    if (itemID.length) {
        if (!out[@"itemId"]) out[@"itemId"] = itemID;
        if (!out[@"listingId"]) out[@"listingId"] = itemID;
    }

    if (!out[@"quantity"]) out[@"quantity"] = @1;
    if (!out[@"quantityRequested"]) out[@"quantityRequested"] = @1;
}

static id EB159Name(id self, SEL _cmd) {
    id value = EB159OrigName ? EB159OrigName(self, _cmd) : nil;
    if ([value isKindOfClass:[NSString class]] &&
        [[(NSString *)value uppercaseString] isEqualToString:@"VI_ADD_TO_CART"]) {
        return @"ADD_TO_CART";
    }
    return value;
}

static id EB159Params(id self, SEL _cmd) {
    id original = EB159OrigParams ? EB159OrigParams(self, _cmd) : nil;

    EB159HarvestSibling(self, original);

    if (!EB159IsAddToCartName(EB159RawName(self))) return original;

    NSMutableDictionary *out = [original isKindOfClass:[NSDictionary class]]
        ? [(NSDictionary *)original mutableCopy] : [NSMutableDictionary dictionary];
    EB159FillLegacyCartFields(out);
    return out;
}

static id EB159Metadata(id self, SEL _cmd) {
    id original = EB159OrigMetadata ? EB159OrigMetadata(self, _cmd) : nil;

    EB159HarvestSibling(self, original);

    if (!EB159IsAddToCartName(EB159RawName(self))) return original;

    NSMutableDictionary *out = [original isKindOfClass:[NSDictionary class]]
        ? [(NSDictionary *)original mutableCopy] : [NSMutableDictionary dictionary];
    EB159FillLegacyCartFields(out);
    return out;
}

static void EB159SetName(id self, SEL _cmd, id value) {
    if (EB159OrigSetName) EB159OrigSetName(self, _cmd, value);

    // If the decoder assigned metadata/params before the action name, harvest
    // them once we know this object is the Buy Box sibling carrying itemId.
    if (EB159IsBuyBoxSiblingName(value)) {
        id params = EB159OrigParams ? EB159OrigParams(self, @selector(params)) : nil;
        id metadata = EB159OrigMetadata ? EB159OrigMetadata(self, @selector(clientPresentationMetadata)) : nil;
        EB159RememberItemID(EB159ItemIDFromDictionary(params));
        EB159RememberItemID(EB159ItemIDFromDictionary(metadata));
    }
}

static void EB159SetParams(id self, SEL _cmd, id value) {
    id name = EB159RawName(self);
    id finalValue = value;

    if (EB159IsBuyBoxSiblingName(name)) {
        EB159RememberItemID(EB159ItemIDFromDictionary(value));
    } else if (EB159IsAddToCartName(name)) {
        NSMutableDictionary *out = [value isKindOfClass:[NSDictionary class]]
            ? [(NSDictionary *)value mutableCopy] : [NSMutableDictionary dictionary];
        EB159FillLegacyCartFields(out);
        finalValue = out;
    }

    if (EB159OrigSetParams) EB159OrigSetParams(self, _cmd, finalValue);
}

static void EB159SetMetadata(id self, SEL _cmd, id value) {
    id name = EB159RawName(self);
    id finalValue = value;

    if (EB159IsBuyBoxSiblingName(name)) {
        EB159RememberItemID(EB159ItemIDFromDictionary(value));
    } else if (EB159IsAddToCartName(name)) {
        NSMutableDictionary *out = [value isKindOfClass:[NSDictionary class]]
            ? [(NSDictionary *)value mutableCopy] : [NSMutableDictionary dictionary];
        EB159FillLegacyCartFields(out);
        finalValue = out;
    }

    if (EB159OrigSetMetadata) EB159OrigSetMetadata(self, _cmd, finalValue);
}

static void EB159Install(void) {
    if (EB159Installed || !EBPrefsEnabled()) return;

    Class cls = objc_getClass("EBNResponseAction");
    if (!cls) return;

    Method nameMethod = class_getInstanceMethod(cls, @selector(name));
    if (!nameMethod) return;

    MSHookMessageEx(cls, @selector(name), (IMP)EB159Name, (IMP *)&EB159OrigName);

    if (class_getInstanceMethod(cls, @selector(params))) {
        MSHookMessageEx(cls, @selector(params), (IMP)EB159Params, (IMP *)&EB159OrigParams);
    }
    if (class_getInstanceMethod(cls, @selector(clientPresentationMetadata))) {
        MSHookMessageEx(cls, @selector(clientPresentationMetadata), (IMP)EB159Metadata, (IMP *)&EB159OrigMetadata);
    }
    if (class_getInstanceMethod(cls, @selector(setName:))) {
        MSHookMessageEx(cls, @selector(setName:), (IMP)EB159SetName, (IMP *)&EB159OrigSetName);
    }
    if (class_getInstanceMethod(cls, @selector(setParams:))) {
        MSHookMessageEx(cls, @selector(setParams:), (IMP)EB159SetParams, (IMP *)&EB159OrigSetParams);
    }
    if (class_getInstanceMethod(cls, @selector(setClientPresentationMetadata:))) {
        MSHookMessageEx(cls, @selector(setClientPresentationMetadata:), (IMP)EB159SetMetadata, (IMP *)&EB159OrigSetMetadata);
    }

    EB159Installed = YES;
}

%ctor {
    @autoreleasepool {
        if (![[[NSBundle mainBundle] bundleIdentifier] isEqualToString:@"com.ebay.iphone"] ||
            !EBPrefsEnabled()) return;

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
