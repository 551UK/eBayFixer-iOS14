#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <substrate.h>
#import "Prefs.h"

static __weak id EB170ActiveContentDataManager = nil;
static id EB170CartManager = nil;
static BOOL EB170Installed = NO;

static BOOL EB170LooksLikeAddToBasketButton(UIButton *button) {
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

static void (*EB170OrigBeginActive)(id, SEL) = NULL;
static void (*EB170OrigEndActive)(id, SEL) = NULL;

static void EB170BeginActive(id self, SEL _cmd) {
    if (EB170OrigBeginActive) EB170OrigBeginActive(self, _cmd);
    EB170ActiveContentDataManager = self;
}

static void EB170EndActive(id self, SEL _cmd) {
    if (EB170ActiveContentDataManager == self) {
        EB170ActiveContentDataManager = nil;
    }
    if (EB170OrigEndActive) EB170OrigEndActive(self, _cmd);
}

static id EB170LiveListing(void) {
    id content = EB170ActiveContentDataManager;
    if (!content) return nil;

    SEL dataManagerSel = @selector(dataManager);
    if (![content respondsToSelector:dataManagerSel]) return nil;

    typedef id (*Getter)(id, SEL);
    id dataManager = ((Getter)objc_msgSend)(content, dataManagerSel);
    if (!dataManager) return nil;

    SEL listingSel = @selector(listing);
    if (![dataManager respondsToSelector:listingSel]) return nil;

    return ((Getter)objc_msgSend)(dataManager, listingSel);
}

static id EB170NativeCartManager(void) {
    @synchronized ([NSObject class]) {
        if (EB170CartManager) return EB170CartManager;

        Class cls = objc_lookUpClass("_TtC14PaymentsModule29ExpSvcShoppingCartDataManager");
        if (!cls) return nil;

        id manager = [[cls alloc] init];
        if (!manager) return nil;

        SEL addSel = NSSelectorFromString(
            @"addListingToCart:preferredShippingCode:selectedByBuyer:itemCustomizationParams:");
        if (![manager respondsToSelector:addSel]) return nil;

        EB170CartManager = manager;
        return EB170CartManager;
    }
}

static BOOL EB170AddLiveListingToCart(void) {
    id listing = EB170LiveListing();
    if (!listing) return NO;

    id manager = EB170NativeCartManager();
    if (!manager) return NO;

    SEL addSel = NSSelectorFromString(
        @"addListingToCart:preferredShippingCode:selectedByBuyer:itemCustomizationParams:");
    Method method = class_getInstanceMethod([manager class], addSel);
    if (!method) return NO;

    typedef void (*AddToCartIMP)(id, SEL, id, NSString *, BOOL, NSDictionary *);
    AddToCartIMP add = (AddToCartIMP)method_getImplementation(method);
    if (!add) return NO;

    // This is the exact modern PaymentsModule ABI in the supplied IPA:
    // the first argument is the live ViewItemDataManager.listing object.
    add(manager, addSel, listing, nil, NO, nil);
    return YES;
}

static void EB170InstallLifecycleHooks(void) {
    if (EB170Installed || !EBPrefsEnabled()) return;

    Class cls = objc_lookUpClass("_TtC11ItemProduct26ViewItemContentDataManager");
    if (!cls) return;

    Method begin = class_getInstanceMethod(cls, @selector(beginActive));
    Method end = class_getInstanceMethod(cls, @selector(endActive));
    if (!begin || !end) return;

    MSHookMessageEx(cls, @selector(beginActive), (IMP)EB170BeginActive, (IMP *)&EB170OrigBeginActive);
    MSHookMessageEx(cls, @selector(endActive), (IMP)EB170EndActive, (IMP *)&EB170OrigEndActive);
    EB170Installed = YES;
}

%hook EUIButton

- (void)handleAction:(id)sender {
    if (EBPrefsEnabled() && EB170LooksLikeAddToBasketButton((UIButton *)self)) {
        if (EB170AddLiveListingToCart()) return;
    }
    %orig;
}

%end

%ctor {
    @autoreleasepool {
        if (![[[NSBundle mainBundle] bundleIdentifier] isEqualToString:@"com.ebay.iphone"] ||
            !EBPrefsEnabled()) return;

        %init;
        EB170InstallLifecycleHooks();

        for (NSNumber *delay in @[@0.05, @0.15, @0.35, @0.75, @1.5, @3.0, @5.0]) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                                         (int64_t)(delay.doubleValue * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{
                EB170InstallLifecycleHooks();
            });
        }
    }
}
