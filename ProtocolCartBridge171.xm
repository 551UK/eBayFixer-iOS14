#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import "Prefs.h"

@interface EB171CartListingProxy : NSObject
@property (nonatomic, copy) NSString *listingID;
@property (nonatomic, copy) NSString *transactionID;
@property (nonatomic, copy) NSString *selectedVariationID;
@property (nonatomic, assign) NSInteger quantityRequested;
@end

@implementation EB171CartListingProxy

- (BOOL)matchWithItem:(id)item allowNoTransaction:(BOOL)allowNoTransaction {
    if (!item) return NO;

    typedef id (*ObjectGetter)(id, SEL);
    ObjectGetter getter = (ObjectGetter)objc_msgSend;

    NSString *otherListingID = nil;
    SEL listingSel = NSSelectorFromString(@"listingID");
    if ([item respondsToSelector:listingSel]) {
        id value = getter(item, listingSel);
        if ([value isKindOfClass:[NSString class]]) otherListingID = value;
        else if ([value isKindOfClass:[NSNumber class]]) otherListingID = [value stringValue];
    }

    if (!self.listingID.length || ![self.listingID isEqualToString:otherListingID ?: @""]) {
        return NO;
    }

    NSString *otherVariationID = nil;
    SEL variationSel = NSSelectorFromString(@"selectedVariationID");
    if ([item respondsToSelector:variationSel]) {
        id value = getter(item, variationSel);
        if ([value isKindOfClass:[NSString class]]) otherVariationID = value;
        else if ([value isKindOfClass:[NSNumber class]]) otherVariationID = [value stringValue];
    }

    if (self.selectedVariationID.length && otherVariationID.length &&
        ![self.selectedVariationID isEqualToString:otherVariationID]) {
        return NO;
    }

    NSString *otherTransactionID = nil;
    SEL transactionSel = NSSelectorFromString(@"transactionID");
    if ([item respondsToSelector:transactionSel]) {
        id value = getter(item, transactionSel);
        if ([value isKindOfClass:[NSString class]]) otherTransactionID = value;
        else if ([value isKindOfClass:[NSNumber class]]) otherTransactionID = [value stringValue];
    }

    if (!allowNoTransaction && self.transactionID.length && otherTransactionID.length &&
        ![self.transactionID isEqualToString:otherTransactionID]) {
        return NO;
    }

    return YES;
}

@end

static NSString *EB171CurrentListingID = nil;
static NSObject *EB171StateLock = nil;

static NSObject *EB171Lock(void) {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        EB171StateLock = [NSObject new];
    });
    return EB171StateLock;
}

static NSString *EB171StringID(id value) {
    if ([value isKindOfClass:[NSString class]] && [(NSString *)value length]) {
        return value;
    }
    if ([value isKindOfClass:[NSNumber class]]) {
        return [(NSNumber *)value stringValue];
    }
    return nil;
}

static NSString *EB171ListingIDFromURL(NSURL *url) {
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

static void EB171RememberListingURL(NSURL *url) {
    NSString *listingID = EB171ListingIDFromURL(url);
    if (!listingID.length) return;

    @synchronized (EB171Lock()) {
        EB171CurrentListingID = [listingID copy];
    }
}

static NSString *EB171ListingID(void) {
    @synchronized (EB171Lock()) {
        return [EB171CurrentListingID copy];
    }
}

static BOOL EB171LooksLikeAddToBasketButton(UIButton *button) {
    if (![button isKindOfClass:[UIButton class]]) return NO;

    for (NSString *value in @[button.currentTitle ?: @"",
                              button.accessibilityLabel ?: @"",
                              button.accessibilityIdentifier ?: @""]) {
        NSString *lower = value.lowercaseString;
        if ([lower containsString:@"add to basket"] ||
            [lower containsString:@"add to cart"] ||
            [lower containsString:@"button_add_to_cart"]) {
            return YES;
        }
    }

    return NO;
}

static id EB171CallObjectGetter(id object, SEL selector) {
    if (!object || !selector || ![object respondsToSelector:selector]) return nil;
    typedef id (*Getter)(id, SEL);
    return ((Getter)objc_msgSend)(object, selector);
}

static id EB171LegacyShoppingCart(void) {
    // eBay 6.192 exposes the already-configured app cart through
    // EBMEBayAppModule.shared.shoppingCart. Use that injected service rather
    // than constructing ExpSvcShoppingCartDataManager ourselves.
    Class moduleClass = objc_lookUpClass("EBMEBayAppModule");
    if (!moduleClass) return nil;

    SEL sharedSel = NSSelectorFromString(@"shared");
    if (![moduleClass respondsToSelector:sharedSel]) return nil;

    id module = EB171CallObjectGetter((id)moduleClass, sharedSel);
    if (!module) return nil;

    return EB171CallObjectGetter(module, NSSelectorFromString(@"shoppingCart"));
}

static BOOL EB171InstallProxyProtocols(void) {
    Class proxyClass = [EB171CartListingProxy class];

    Protocol *request =
        objc_getProtocol("_TtP12ModuleLinker26ListingCartRequestProtocol_");
    Protocol *comparison =
        objc_getProtocol("_TtP12ModuleLinker25ListingComparisonProtocol_");
    Protocol *cartListing =
        objc_getProtocol("_TtP12ModuleLinker19CartListingProtocol_");

    if (request) class_addProtocol(proxyClass, request);
    if (comparison) class_addProtocol(proxyClass, comparison);
    if (cartListing) class_addProtocol(proxyClass, cartListing);

    return cartListing != nil || request != nil;
}

static BOOL EB171DirectLegacyCartAdd(void) {
    NSString *listingID = EB171ListingID();
    if (!listingID.length) return NO;

    id shoppingCart = EB171LegacyShoppingCart();
    if (!shoppingCart) return NO;

    SEL addSel = NSSelectorFromString(
        @"addListingToCart:preferredShippingCode:selectedByBuyer:itemCustomizationParams:");
    if (![shoppingCart respondsToSelector:addSel]) return NO;

    EB171CartListingProxy *listing = [EB171CartListingProxy new];
    listing.listingID = listingID;
    listing.transactionID = nil;
    listing.selectedVariationID = nil;
    listing.quantityRequested = 1;

    typedef void (*AddToCart)(id, SEL, id, NSString *, BOOL, NSDictionary *);
    ((AddToCart)objc_msgSend)(shoppingCart, addSel, listing, nil, NO, nil);
    return YES;
}

%hook NSURLSession

- (NSURLSessionDataTask *)dataTaskWithRequest:(NSURLRequest *)request {
    if (EBPrefsEnabled()) EB171RememberListingURL(request.URL);
    return %orig;
}

- (NSURLSessionDataTask *)dataTaskWithRequest:(NSURLRequest *)request
                            completionHandler:(void (^)(NSData *, NSURLResponse *, NSError *))handler {
    if (EBPrefsEnabled()) EB171RememberListingURL(request.URL);
    return %orig;
}

- (NSURLSessionDataTask *)dataTaskWithURL:(NSURL *)url {
    if (EBPrefsEnabled()) EB171RememberListingURL(url);
    return %orig;
}

- (NSURLSessionDataTask *)dataTaskWithURL:(NSURL *)url
                       completionHandler:(void (^)(NSData *, NSURLResponse *, NSError *))handler {
    if (EBPrefsEnabled()) EB171RememberListingURL(url);
    return %orig;
}

%end

%hook EUIButton

- (void)handleAction:(id)sender {
    if (EBPrefsEnabled() && EB171LooksLikeAddToBasketButton((UIButton *)self)) {
        if (EB171DirectLegacyCartAdd()) return;
    }
    %orig;
}

%end

%ctor {
    @autoreleasepool {
        if (![[[NSBundle mainBundle] bundleIdentifier] isEqualToString:@"com.ebay.iphone"] ||
            !EBPrefsEnabled()) return;

        EB171InstallProxyProtocols();
        %init;
    }
}
