#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import "Prefs.h"

@interface EB171CartListingProxy : NSObject
@property (nonatomic, copy) NSString *listingID;
@property (nonatomic, copy) NSString *selectedVariationID;
@property (nonatomic, assign) NSInteger quantityRequested;
@end

@implementation EB171CartListingProxy

// These are required by ModuleLinker.ListingCartRequestProtocol in the
// eBay binary. A normal fixed-price item does not need object-backed
// transaction or variation models, so nil is the correct empty value.
- (id)transaction {
    return nil;
}

- (id)selectedVariation {
    return nil;
}

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

    return YES;
}

@end

static NSString *EB171CurrentListingID = nil;
static NSString *EB171CurrentVariationID = nil;
static NSObject *EB171StateLock = nil;
static BOOL EB171HandlingDirectAdd = NO;

static NSObject *EB171Lock(void) {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        EB171StateLock = [NSObject new];
    });
    return EB171StateLock;
}

static void EB171RememberListingURL(NSURL *url) {
    if (!url) return;

    NSString *path = url.path.lowercaseString ?: @"";
    if (![path containsString:@"/experience/listing_details/"]) return;

    NSURLComponents *components =
        [NSURLComponents componentsWithURL:url resolvingAgainstBaseURL:NO];

    NSString *listingID = nil;
    NSString *variationID = nil;

    for (NSURLQueryItem *item in components.queryItems ?: @[]) {
        NSString *name = item.name.lowercaseString ?: @"";
        if (([name isEqualToString:@"item_id"] ||
             [name isEqualToString:@"itemid"] ||
             [name isEqualToString:@"listingid"]) && item.value.length) {
            listingID = item.value;
        } else if (([name isEqualToString:@"variation_id"] ||
                    [name isEqualToString:@"variationid"]) && item.value.length) {
            variationID = item.value;
        }
    }

    if (!listingID.length) return;

    @synchronized (EB171Lock()) {
        EB171CurrentListingID = [listingID copy];
        EB171CurrentVariationID = [variationID copy];
    }
}

static NSString *EB171ListingID(void) {
    @synchronized (EB171Lock()) {
        return [EB171CurrentListingID copy];
    }
}

static NSString *EB171VariationID(void) {
    @synchronized (EB171Lock()) {
        return [EB171CurrentVariationID copy];
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
            [lower containsString:@"button_add_to_cart"] ||
            [lower containsString:@"buttonaddtocart"]) {
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

static id EB171ShoppingCart(void) {
    // Use the cart service already wired into the running eBay application.
    // Constructing PaymentsModule managers by hand misses dependencies.
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

    // The addListingToCart ABI in ModuleLinker requires the argument to
    // conform to all four of these protocols, not just CartRequest.
    Protocol *mts =
        objc_getProtocol("_TtP12ModuleLinker22ListingCartMTSProtocol_");
    Protocol *request =
        objc_getProtocol("_TtP12ModuleLinker26ListingCartRequestProtocol_");
    Protocol *comparison =
        objc_getProtocol("_TtP12ModuleLinker25ListingComparisonProtocol_");
    Protocol *listing =
        objc_getProtocol("_TtP12ModuleLinker15ListingProtocol_");

    if (!mts || !request || !comparison || !listing) return NO;

    class_addProtocol(proxyClass, mts);
    class_addProtocol(proxyClass, request);
    class_addProtocol(proxyClass, comparison);
    class_addProtocol(proxyClass, listing);

    return class_conformsToProtocol(proxyClass, mts) &&
           class_conformsToProtocol(proxyClass, request) &&
           class_conformsToProtocol(proxyClass, comparison) &&
           class_conformsToProtocol(proxyClass, listing);
}

static BOOL EB171DirectCartAdd(void) {
    if (EB171HandlingDirectAdd) return NO;
    if (!EB171InstallProxyProtocols()) return NO;

    NSString *listingID = EB171ListingID();
    if (!listingID.length) return NO;

    id shoppingCart = EB171ShoppingCart();
    if (!shoppingCart) return NO;

    SEL addSel = NSSelectorFromString(
        @"addListingToCart:preferredShippingCode:selectedByBuyer:itemCustomizationParams:");
    if (![shoppingCart respondsToSelector:addSel]) return NO;

    EB171CartListingProxy *listing = [EB171CartListingProxy new];
    listing.listingID = listingID;
    listing.selectedVariationID = EB171VariationID();
    listing.quantityRequested = 1;

    EB171HandlingDirectAdd = YES;
    typedef void (*AddToCart)(id, SEL, id, NSString *, BOOL, NSDictionary *);
    ((AddToCart)objc_msgSend)(shoppingCart, addSel, listing, nil, NO, nil);
    EB171HandlingDirectAdd = NO;
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

// Catch the UIKit action dispatch before eBay's older action handler can drop
// VI_ADD_TO_CART. This is independent of the EUIButton handleAction path.
%hook UIControl

- (void)sendAction:(SEL)action to:(id)target forEvent:(UIEvent *)event {
    if (EBPrefsEnabled() && !EB171HandlingDirectAdd &&
        [self isKindOfClass:[UIButton class]] &&
        EB171LooksLikeAddToBasketButton((UIButton *)self)) {
        if (EB171DirectCartAdd()) return;
    }

    %orig;
}

%end

// Keep the eBay-specific hook as a fallback for custom button dispatch.
%hook EUIButton

- (void)handleAction:(id)sender {
    if (EBPrefsEnabled() && !EB171HandlingDirectAdd &&
        EB171LooksLikeAddToBasketButton((UIButton *)self)) {
        if (EB171DirectCartAdd()) return;
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
