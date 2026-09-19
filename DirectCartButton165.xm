#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <mach-o/dyld.h>
#import <dlfcn.h>
#import "Prefs.h"

static __weak UIViewController *EB165CurrentViewItemController = nil;

static BOOL EB165LooksLikeAddToBasketButton(UIButton *button) {
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

static Ivar EB165FindObjectIvar(Class cls, NSArray<NSString *> *names) {
    for (Class cur = cls; cur; cur = class_getSuperclass(cur)) {
        for (NSString *name in names) {
            Ivar ivar = class_getInstanceVariable(cur, name.UTF8String);
            if (!ivar) continue;
            const char *type = ivar_getTypeEncoding(ivar);
            if (type && type[0] == '@') return ivar;
        }
    }
    return NULL;
}

static id EB165GetObjectIvar(id object, NSArray<NSString *> *names) {
    if (!object) return nil;
    Ivar ivar = EB165FindObjectIvar(object_getClass(object), names);
    return ivar ? object_getIvar(object, ivar) : nil;
}

static id EB165CurrentListing(void) {
    UIViewController *vc = EB165CurrentViewItemController;
    if (!vc) return nil;

    id contentManager = EB165GetObjectIvar(vc, @[@"_contentDataManager", @"contentDataManager"]);
    if (!contentManager) return nil;

    id dataManager = EB165GetObjectIvar(contentManager, @[@"dataManager", @"_dataManager"]);
    if (!dataManager) return nil;

    return EB165GetObjectIvar(dataManager, @[@"_listing", @"listing"]);
}

static BOOL EB165ListingSupportsCart(id listing) {
    if (!listing) return NO;

    NSArray<NSString *> *protocolNames = @[
        @"_TtP12ModuleLinker22ListingCartMTSProtocol_",
        @"_TtP12ModuleLinker26ListingCartRequestProtocol_",
        @"_TtP12ModuleLinker25ListingComparisonProtocol_",
        @"_TtP12ModuleLinker15ListingProtocol_"
    ];

    for (NSString *name in protocolNames) {
        Protocol *protocol = objc_getProtocol(name.UTF8String);
        if (!protocol || ![listing conformsToProtocol:protocol]) return NO;
    }
    return YES;
}

static void *EB165PaymentsModuleHandle(void) {
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

static id EB165SharedCartManager(void) {
    void *handle = EB165PaymentsModuleHandle();
    if (!handle) return nil;

    // Swift static getter:
    // PaymentsModule.ExpSvcShoppingCartDataManager.shared.getter
    const char *symbol =
        "$s14PaymentsModule29ExpSvcShoppingCartDataManagerC6sharedACvgZ";

    void *raw = dlsym(handle, symbol);
    if (!raw) return nil;

    typedef id (*SharedGetter)(void);
    SharedGetter getter = (SharedGetter)raw;
    return getter ? getter() : nil;
}

static BOOL EB165DirectAddToCart(void) {
    id listing = EB165CurrentListing();
    if (!EB165ListingSupportsCart(listing)) return NO;

    id manager = EB165SharedCartManager();
    if (!manager) return NO;

    SEL selector = NSSelectorFromString(
        @"addListingToCart:preferredShippingCode:selectedByBuyer:itemCustomizationParams:");
    Method method = class_getInstanceMethod(object_getClass(manager), selector);
    if (!method) return NO;

    // The selector's first argument is NOT a listing-ID NSString. It is the
    // live View Item listing object conforming to ListingCartMTSProtocol,
    // ListingCartRequestProtocol, ListingComparisonProtocol and
    // ListingProtocol. Using the ID string here was the v1.0.63 crash.
    typedef void (*AddToCartIMP)(id, SEL, id, NSString *, BOOL, NSDictionary *);
    AddToCartIMP add = (AddToCartIMP)method_getImplementation(method);
    if (!add) return NO;

    add(manager, selector, listing, nil, NO, nil);
    return YES;
}

@interface EBUViewItemViewController : UIViewController
@end

%hook EBUViewItemViewController

- (void)viewDidAppear:(BOOL)animated {
    %orig;
    EB165CurrentViewItemController = self;
}

- (void)viewDidDisappear:(BOOL)animated {
    %orig;
    if (EB165CurrentViewItemController == self) {
        EB165CurrentViewItemController = nil;
    }
}

%end

%hook EUIButton

- (void)handleAction:(id)sender {
    if (EBPrefsEnabled() && EB165LooksLikeAddToBasketButton((UIButton *)self)) {
        if (EB165DirectAddToCart()) return;
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
