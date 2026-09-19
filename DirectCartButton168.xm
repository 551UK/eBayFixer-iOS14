#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import "Prefs.h"

static NSString *EB168CurrentListingID = nil;
static id EB168CartManager = nil;
static NSObject *EB168StateLock = nil;

static NSObject *EB168Lock(void) {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        EB168StateLock = [NSObject new];
    });
    return EB168StateLock;
}

static BOOL EB168LooksLikeAddToBasketButton(UIButton *button) {
    if (![button isKindOfClass:[UIButton class]]) return NO;

    NSArray *values = @[
        button.currentTitle ?: @"",
        button.accessibilityLabel ?: @"",
        button.accessibilityIdentifier ?: @""
    ];

    for (NSString *value in values) {
        NSString *lower = value.lowercaseString;
        if ([lower containsString:@"add to basket"] ||
            [lower containsString:@"add to cart"] ||
            [lower containsString:@"button_add_to_cart"]) {
            return YES;
        }
    }
    return NO;
}

static NSString *EB168ListingIDFromURL(NSURL *url) {
    if (!url) return nil;

    NSString *path = url.path.lowercaseString ?: @"";
    if (![path containsString:@"/experience/listing_details/"]) return nil;

    NSURLComponents *components =
        [NSURLComponents componentsWithURL:url resolvingAgainstBaseURL:NO];

    for (NSURLQueryItem *item in components.queryItems ?: @[]) {
        NSString *name = item.name.lowercaseString ?: @"";
        if ([name isEqualToString:@"item_id"] ||
            [name isEqualToString:@"itemid"] ||
            [name isEqualToString:@"listingid"]) {
            if (item.value.length) return item.value;
        }
    }
    return nil;
}

static void EB168RememberListingURL(NSURL *url) {
    NSString *listingID = EB168ListingIDFromURL(url);
    if (!listingID.length) return;

    @synchronized (EB168Lock()) {
        EB168CurrentListingID = [listingID copy];
    }
}

static NSString *EB168ListingID(void) {
    @synchronized (EB168Lock()) {
        return [EB168CurrentListingID copy];
    }
}

static Class EB168AddToCartListingClass(void) {
    Class cls = objc_lookUpClass("_TtC11ItemProduct16AddToCartListing");
    if (cls) return cls;

    // Equivalent Swift runtime name, kept only as a safe fallback.
    return NSClassFromString(@"ItemProduct.AddToCartListing");
}

static id EB168MakeLegacyCartListing(NSString *listingID) {
    if (!listingID.length) return nil;

    Class cls = EB168AddToCartListingClass();
    if (!cls) return nil;

    id cartListing = [[cls alloc] init];
    if (!cartListing) return nil;

    SEL setListingID = NSSelectorFromString(@"setListingID:");
    SEL setQuantity = NSSelectorFromString(@"setQuantityRequested:");
    if (![cartListing respondsToSelector:setListingID] ||
        ![cartListing respondsToSelector:setQuantity]) {
        return nil;
    }

    typedef void (*ObjectSetter)(id, SEL, id);
    typedef void (*IntegerSetter)(id, SEL, NSInteger);

    ((ObjectSetter)objc_msgSend)(cartListing, setListingID, listingID);
    ((IntegerSetter)objc_msgSend)(cartListing, setQuantity, (NSInteger)1);

    // 6.192 exposes this exact concrete object as
    // ModuleLinker.CartListingProtocol. transactionID and selectedVariationID
    // are optional for a normal single-SKU View Item add-to-cart request.
    return cartListing;
}

static id EB168LegacyCartManager(void) {
    @synchronized (EB168Lock()) {
        if (EB168CartManager) return EB168CartManager;

        Class cls = objc_lookUpClass("_TtC14PaymentsModule29ExpSvcShoppingCartDataManager");
        if (!cls) return nil;

        id manager = [[cls alloc] init];
        if (!manager) return nil;

        SEL selector = NSSelectorFromString(
            @"addListingToCart:preferredShippingCode:selectedByBuyer:itemCustomizationParams:");
        if (![manager respondsToSelector:selector]) return nil;

        EB168CartManager = manager;
        return EB168CartManager;
    }
}

static BOOL EB168DirectAddToCart(void) {
    NSString *listingID = EB168ListingID();
    if (!listingID.length) return NO;

    id cartListing = EB168MakeLegacyCartListing(listingID);
    if (!cartListing) return NO;

    id manager = EB168LegacyCartManager();
    if (!manager) return NO;

    SEL selector = NSSelectorFromString(
        @"addListingToCart:preferredShippingCode:selectedByBuyer:itemCustomizationParams:");

    Method method = class_getInstanceMethod([manager class], selector);
    if (!method) return NO;

    typedef void (*AddToCartIMP)(id, SEL, id, NSString *, BOOL, NSDictionary *);
    AddToCartIMP add = (AddToCartIMP)method_getImplementation(method);
    if (!add) return NO;

    add(manager, selector, cartListing, nil, NO, nil);
    return YES;
}

%hook NSURLSession

- (NSURLSessionDataTask *)dataTaskWithRequest:(NSURLRequest *)request {
    if (EBPrefsEnabled()) EB168RememberListingURL(request.URL);
    return %orig;
}

- (NSURLSessionDataTask *)dataTaskWithRequest:(NSURLRequest *)request
                            completionHandler:(void (^)(NSData *, NSURLResponse *, NSError *))handler {
    if (EBPrefsEnabled()) EB168RememberListingURL(request.URL);
    return %orig;
}

- (NSURLSessionDataTask *)dataTaskWithURL:(NSURL *)url {
    if (EBPrefsEnabled()) EB168RememberListingURL(url);
    return %orig;
}

- (NSURLSessionDataTask *)dataTaskWithURL:(NSURL *)url
                       completionHandler:(void (^)(NSData *, NSURLResponse *, NSError *))handler {
    if (EBPrefsEnabled()) EB168RememberListingURL(url);
    return %orig;
}

%end

%hook EUIButton

- (void)handleAction:(id)sender {
    if (EBPrefsEnabled() && EB168LooksLikeAddToBasketButton((UIButton *)self)) {
        if (EB168DirectAddToCart()) return;
    }
    %orig;
}

%end

%ctor {
    @autoreleasepool {
        if (![[[NSBundle mainBundle] bundleIdentifier] isEqualToString:@"com.ebay.iphone"] ||
            !EBPrefsEnabled()) return;
        %init;
    }
}
