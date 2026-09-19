#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import "Prefs.h"

static NSString *EB163CurrentListingID = nil;
static id EB163CartManager = nil;
static NSObject *EB163Lock(void) {
    static NSObject *lock;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{ lock = [NSObject new]; });
    return lock;
}

static NSString *EB163ListingIDFromURL(NSURL *url) {
    if (!url) return nil;
    NSString *path = url.path.lowercaseString ?: @"";
    if (![path containsString:@"/experience/listing_details/"]) return nil;

    NSURLComponents *components = [NSURLComponents componentsWithURL:url resolvingAgainstBaseURL:NO];
    for (NSURLQueryItem *item in components.queryItems ?: @[]) {
        NSString *name = item.name ?: @"";
        if ([name isEqualToString:@"itemId"] ||
            [name isEqualToString:@"item_id"] ||
            [name isEqualToString:@"listingId"] ||
            [name isEqualToString:@"listingID"]) {
            if (item.value.length) return item.value;
        }
    }
    return nil;
}

static void EB163RememberListingID(NSURL *url) {
    NSString *itemID = EB163ListingIDFromURL(url);
    if (!itemID.length) return;
    @synchronized (EB163Lock()) {
        EB163CurrentListingID = [itemID copy];
    }
}

static NSString *EB163ListingID(void) {
    @synchronized (EB163Lock()) {
        return [EB163CurrentListingID copy];
    }
}

static BOOL EB163LooksLikeAddToBasketButton(UIButton *button) {
    if (![button isKindOfClass:[UIButton class]]) return NO;

    NSMutableArray *values = [NSMutableArray array];
    if (button.currentTitle.length) [values addObject:button.currentTitle];
    if (button.accessibilityLabel.length) [values addObject:button.accessibilityLabel];
    if (button.accessibilityIdentifier.length) [values addObject:button.accessibilityIdentifier];

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

static BOOL EB163DirectAddToCart(void) {
    NSString *listingID = EB163ListingID();
    if (!listingID.length) return NO;

    Class cls = objc_getClass("_TtC14PaymentsModule29ExpSvcShoppingCartDataManager");
    if (!cls) return NO;

    SEL addSel = NSSelectorFromString(@"addListingToCart:preferredShippingCode:selectedByBuyer:itemCustomizationParams:");
    Method method = class_getInstanceMethod(cls, addSel);
    if (!method) return NO;

    @synchronized (EB163Lock()) {
        if (!EB163CartManager) {
            EB163CartManager = [[cls alloc] init];
        }
    }
    if (!EB163CartManager) return NO;

    typedef void (*AddFn)(id, SEL, id, id, BOOL, id);
    AddFn add = (AddFn)method_getImplementation(method);
    if (!add) return NO;

    // This is the native cart method used by eBay itself. Bypass the dead
    // VI_ADD_TO_CART action-dispatch path and call the cart data manager
    // directly with the listing currently shown on View Item.
    add(EB163CartManager, addSel, listingID, nil, NO, nil);
    return YES;
}

%hook NSURLSession

- (NSURLSessionDataTask *)dataTaskWithRequest:(NSURLRequest *)request {
    if (EBPrefsEnabled()) EB163RememberListingID(request.URL);
    return %orig;
}

- (NSURLSessionDataTask *)dataTaskWithRequest:(NSURLRequest *)request
                            completionHandler:(void (^)(NSData *, NSURLResponse *, NSError *))handler {
    if (EBPrefsEnabled()) EB163RememberListingID(request.URL);
    return %orig;
}

%end

%hook EUIButton

- (void)handleAction:(id)sender {
    if (EBPrefsEnabled() && EB163LooksLikeAddToBasketButton((UIButton *)self)) {
        if (EB163DirectAddToCart()) return;
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
