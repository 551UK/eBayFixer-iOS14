#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <mach-o/dyld.h>
#import <dlfcn.h>
#import "Prefs.h"

static BOOL EB166LooksLikeAddToBasketButton(UIButton *button) {
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

static id EB166CallObjectGetter(id object, NSString *name) {
    if (!object || !name.length) return nil;
    SEL sel = NSSelectorFromString(name);
    if (![object respondsToSelector:sel]) return nil;

    typedef id (*GetterFn)(id, SEL);
    GetterFn fn = (GetterFn)objc_msgSend;
    return fn(object, sel);
}

static id EB166GetObjectIvar(id object, NSString *name) {
    if (!object || !name.length) return nil;

    for (Class cls = object_getClass(object); cls; cls = class_getSuperclass(cls)) {
        Ivar ivar = class_getInstanceVariable(cls, name.UTF8String);
        if (!ivar) continue;

        const char *type = ivar_getTypeEncoding(ivar);
        if (!type || type[0] != '@') continue;
        return object_getIvar(object, ivar);
    }
    return nil;
}

static id EB166NamedObject(id object, NSArray<NSString *> *names) {
    for (NSString *name in names) {
        id value = EB166CallObjectGetter(object, name);
        if (value) return value;

        value = EB166GetObjectIvar(object, name);
        if (value) return value;

        if (![name hasPrefix:@"_"]) {
            value = EB166GetObjectIvar(object, [@"_" stringByAppendingString:name]);
            if (value) return value;
        }
    }
    return nil;
}

static UIViewController *EB166ViewControllerForButton(UIButton *button) {
    UIResponder *node = button;
    for (NSUInteger i = 0; node && i < 20; i++) {
        if ([node isKindOfClass:[UIViewController class]]) {
            return (UIViewController *)node;
        }
        node = node.nextResponder;
    }
    return nil;
}

static BOOL EB166ConformsToLegacyCartListing(id object) {
    if (!object) return NO;

    // eBay 6.192 (the closest old binary available to 6.96) shows the
    // addListingToCart entry point taking ListingCartRequestProtocol only.
    // The four-protocol requirement used in 1.0.65 belongs to much newer
    // eBay builds and causes the legacy 6.96 path to reject the live model.
    Protocol *protocol = objc_getProtocol("_TtP12ModuleLinker26ListingCartRequestProtocol_");
    return protocol && [object conformsToProtocol:protocol];
}

static id EB166FindLegacyListingFromObject(id root) {
    if (!root) return nil;
    if (EB166ConformsToLegacyCartListing(root)) return root;

    // Follow only known View Item model links present in the old ItemProduct
    // binary. This is intentionally bounded and does not enumerate runtime
    // classes or arbitrary ivars.
    NSArray<NSArray<NSString *> *> *paths = @[
        @[@"contentDataManager"],
        @[@"contentDataManager", @"dataManager"],
        @[@"contentDataManager", @"dataManager", @"listing"],
        @[@"contentDataManager", @"listing"],
        @[@"dataManager"],
        @[@"dataManager", @"listing"],
        @[@"listing"],
        @[@"viewModel"],
        @[@"viewModel", @"dataManager"],
        @[@"viewModel", @"dataManager", @"listing"],
        @[@"modelManager"],
        @[@"modelManager", @"listing"],
        @[@"contentController"],
        @[@"contentController", @"contentDataManager"],
        @[@"contentController", @"contentDataManager", @"dataManager"],
        @[@"contentController", @"contentDataManager", @"dataManager", @"listing"]
    ];

    for (NSArray<NSString *> *path in paths) {
        id value = root;
        for (NSString *name in path) {
            value = EB166NamedObject(value, @[name,
                                              [@"$__lazy_storage_$_" stringByAppendingString:name]]);
            if (!value) break;
        }
        if (EB166ConformsToLegacyCartListing(value)) return value;
    }

    return nil;
}

static id EB166CurrentListingForButton(UIButton *button) {
    UIViewController *vc = EB166ViewControllerForButton(button);
    for (NSUInteger i = 0; vc && i < 8; i++) {
        id listing = EB166FindLegacyListingFromObject(vc);
        if (listing) return listing;

        // The visible Buy Box can live inside a child controller while its
        // View Item model is owned by a parent.
        vc = vc.parentViewController;
    }
    return nil;
}

static void *EB166PaymentsModuleHandle(void) {
    static void *handle = NULL;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        uint32_t count = _dyld_image_count();
        for (uint32_t i = 0; i < count; i++) {
            const char *path = _dyld_get_image_name(i);
            if (!path || !strstr(path, "/PaymentsModule.framework/PaymentsModule")) continue;
            handle = dlopen(path, RTLD_LAZY);
            if (handle) break;
        }
    });
    return handle;
}

static id EB166SharedCartManager(void) {
    void *handle = EB166PaymentsModuleHandle();
    if (!handle) return nil;

    // PaymentsModule.ExpSvcShoppingCartDataManager.shared.getter
    const char *symbol =
        "$s14PaymentsModule29ExpSvcShoppingCartDataManagerC6sharedACvgZ";

    void *raw = dlsym(handle, symbol);
    if (!raw) return nil;

    typedef id (*SharedGetter)(void);
    SharedGetter getter = (SharedGetter)raw;
    return getter ? getter() : nil;
}

static BOOL EB166DirectAddToCart(UIButton *button) {
    id listing = EB166CurrentListingForButton(button);
    if (!listing) return NO;

    id manager = EB166SharedCartManager();
    if (!manager) return NO;

    SEL selector = NSSelectorFromString(
        @"addListingToCart:preferredShippingCode:selectedByBuyer:itemCustomizationParams:");
    Method method = class_getInstanceMethod(object_getClass(manager), selector);
    if (!method) return NO;

    typedef void (*AddToCartIMP)(id, SEL, id, NSString *, BOOL, NSDictionary *);
    AddToCartIMP add = (AddToCartIMP)method_getImplementation(method);
    if (!add) return NO;

    add(manager, selector, listing, nil, NO, nil);
    return YES;
}

%hook EUIButton

- (void)handleAction:(id)sender {
    if (EBPrefsEnabled() && EB166LooksLikeAddToBasketButton((UIButton *)self)) {
        if (EB166DirectAddToCart((UIButton *)self)) return;
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
