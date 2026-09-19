#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import "Prefs.h"

static id EB167CartManager = nil;

static BOOL EB167LooksLikeAddToBasketButton(UIButton *button) {
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

static id EB167ObjectGetter(id object, NSString *name) {
    if (!object || !name.length) return nil;
    SEL sel = NSSelectorFromString(name);
    if (![object respondsToSelector:sel]) return nil;

    typedef id (*GetterFn)(id, SEL);
    return ((GetterFn)objc_msgSend)(object, sel);
}

static id EB167ObjectIvar(id object, NSString *name) {
    if (!object || !name.length) return nil;

    for (Class cls = object_getClass(object); cls; cls = class_getSuperclass(cls)) {
        Ivar ivar = class_getInstanceVariable(cls, name.UTF8String);
        if (!ivar) continue;

        const char *type = ivar_getTypeEncoding(ivar);
        if (type && type[0] == '@') return object_getIvar(object, ivar);
    }
    return nil;
}

static id EB167NamedObject(id object, NSString *name) {
    id value = EB167ObjectGetter(object, name);
    if (value) return value;

    value = EB167ObjectIvar(object, name);
    if (value) return value;

    if (![name hasPrefix:@"_"]) {
        value = EB167ObjectIvar(object, [@"_" stringByAppendingString:name]);
        if (value) return value;
    }
    return nil;
}

static NSString *EB167StringValue(id value) {
    if ([value isKindOfClass:[NSString class]] && [(NSString *)value length]) {
        return (NSString *)value;
    }
    if ([value isKindOfClass:[NSNumber class]]) {
        return [(NSNumber *)value stringValue];
    }
    return nil;
}

static NSString *EB167StringProperty(id object, NSArray<NSString *> *names) {
    for (NSString *name in names) {
        NSString *value = EB167StringValue(EB167NamedObject(object, name));
        if (value.length) return value;
    }
    return nil;
}

static UIViewController *EB167ViewControllerForButton(UIButton *button) {
    UIResponder *node = button;
    for (NSUInteger i = 0; node && i < 24; i++) {
        if ([node isKindOfClass:[UIViewController class]]) {
            return (UIViewController *)node;
        }
        node = node.nextResponder;
    }
    return nil;
}

static id EB167ViewItemDataManagerForButton(UIButton *button) {
    UIViewController *vc = EB167ViewControllerForButton(button);

    for (NSUInteger depth = 0; vc && depth < 10; depth++, vc = vc.parentViewController) {
        id content = EB167NamedObject(vc, @"contentDataManager");
        if (!content) {
            id contentController = EB167NamedObject(vc, @"contentController");
            content = EB167NamedObject(contentController, @"contentDataManager");
        }

        id dataManager = EB167NamedObject(content, @"dataManager");
        if (!dataManager) dataManager = EB167NamedObject(vc, @"dataManager");

        if (dataManager &&
            ([dataManager respondsToSelector:NSSelectorFromString(@"listing")] ||
             EB167ObjectIvar(dataManager, @"_listing"))) {
            return dataManager;
        }
    }
    return nil;
}

static id EB167LegacyCartListing(UIButton *button) {
    id dataManager = EB167ViewItemDataManagerForButton(button);
    if (!dataManager) return nil;

    id liveListing = EB167NamedObject(dataManager, @"listing");

    NSString *listingID =
        EB167StringProperty(liveListing, @[@"listingID", @"listingId", @"itemID", @"itemId"]) ?:
        EB167StringProperty(dataManager, @[@"listingID", @"listingId", @"itemID", @"itemId"]);
    if (!listingID.length) return nil;

    NSString *transactionID =
        EB167StringProperty(liveListing, @[@"transactionID", @"transactionId"]) ?:
        EB167StringProperty(dataManager, @[@"transactionID", @"transactionId"]);

    NSString *variationID =
        EB167StringProperty(dataManager, @[@"lastSelectedVariationID", @"selectedVariationID", @"selectedVariationId"]) ?:
        EB167StringProperty(liveListing, @[@"selectedVariationID", @"selectedVariationId", @"variationID", @"variationId"]);

    Class cartListingClass = objc_getClass("_TtC11ItemProduct16AddToCartListing");
    if (!cartListingClass) return nil;

    id cartListing = [[cartListingClass alloc] init];
    if (!cartListing) return nil;

    SEL setListing = NSSelectorFromString(@"setListingID:");
    SEL setTransaction = NSSelectorFromString(@"setTransactionID:");
    SEL setVariation = NSSelectorFromString(@"setSelectedVariationID:");
    SEL setQuantity = NSSelectorFromString(@"setQuantityRequested:");

    if (![cartListing respondsToSelector:setListing] ||
        ![cartListing respondsToSelector:setQuantity]) {
        return nil;
    }

    typedef void (*ObjectSetterFn)(id, SEL, id);
    typedef void (*IntegerSetterFn)(id, SEL, NSInteger);

    ((ObjectSetterFn)objc_msgSend)(cartListing, setListing, listingID);
    if ([cartListing respondsToSelector:setTransaction]) {
        ((ObjectSetterFn)objc_msgSend)(cartListing, setTransaction, transactionID);
    }
    if ([cartListing respondsToSelector:setVariation]) {
        ((ObjectSetterFn)objc_msgSend)(cartListing, setVariation, variationID);
    }
    ((IntegerSetterFn)objc_msgSend)(cartListing, setQuantity, (NSInteger)1);

    // The legacy 6.192-era PaymentsModule entry point takes exactly
    // ModuleLinker.CartListingProtocol. The concrete AddToCartListing class
    // exists specifically to provide that bridge for View Item.
    Protocol *legacyProtocol = objc_getProtocol("_TtP12ModuleLinker19CartListingProtocol_");
    if (legacyProtocol && ![cartListing conformsToProtocol:legacyProtocol]) return nil;

    return cartListing;
}

static id EB167LegacyCartManager(void) {
    @synchronized ([NSObject class]) {
        if (EB167CartManager) return EB167CartManager;

        Class managerClass = objc_getClass("_TtC14PaymentsModule29ExpSvcShoppingCartDataManager");
        if (!managerClass) return nil;

        // The legacy 6.192-era binary has no exported Swift .shared getter for
        // this class. v1.0.63 proved a normal instance reaches PaymentsModule;
        // retain that manager so its async cart request can finish.
        EB167CartManager = [[managerClass alloc] init];
        return EB167CartManager;
    }
}

static BOOL EB167DirectAddToCart(UIButton *button) {
    id cartListing = EB167LegacyCartListing(button);
    if (!cartListing) return NO;

    id manager = EB167LegacyCartManager();
    if (!manager) return NO;

    SEL selector = NSSelectorFromString(
        @"addListingToCart:preferredShippingCode:selectedByBuyer:itemCustomizationParams:");

    // Use the actual instance class. object_getClass(manager) is the metaclass
    // and was the reason the 1.0.65/1.0.66 lookup could silently return nil.
    Class managerClass = [manager class];
    Method method = class_getInstanceMethod(managerClass, selector);
    if (!method) return NO;

    typedef void (*AddToCartIMP)(id, SEL, id, NSString *, BOOL, NSDictionary *);
    AddToCartIMP add = (AddToCartIMP)method_getImplementation(method);
    if (!add) return NO;

    add(manager, selector, cartListing, nil, NO, nil);
    return YES;
}

%hook EUIButton

- (void)handleAction:(id)sender {
    if (EBPrefsEnabled() && EB167LooksLikeAddToBasketButton((UIButton *)self)) {
        if (EB167DirectAddToCart((UIButton *)self)) return;
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
