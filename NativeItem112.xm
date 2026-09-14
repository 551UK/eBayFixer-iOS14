#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <substrate.h>

static NSMutableSet *EB112InstalledHooks(void) {
    static NSMutableSet *set;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{ set = [NSMutableSet set]; });
    return set;
}

static BOOL EB112Yes(id self, SEL _cmd) { return YES; }

static BOOL EB112HookBool(Class cls, NSString *selectorName) {
    if (!cls || selectorName.length == 0) return NO;
    SEL selector = NSSelectorFromString(selectorName);
    if (!class_getInstanceMethod(cls, selector)) return NO;

    NSString *key = [NSString stringWithFormat:@"%@::%@", NSStringFromClass(cls), selectorName];
    @synchronized (EB112InstalledHooks()) {
        if ([EB112InstalledHooks() containsObject:key]) return YES;
        MSHookMessageEx(cls, selector, (IMP)EB112Yes, NULL);
        [EB112InstalledHooks() addObject:key];
    }
    return YES;
}

static void EB112InstallItemV2Hooks(void) {
    NSArray *classes = @[
        @"_TtC11ItemProduct29ObjCItemProductFeatureToggles",
        @"ObjCItemProductFeatureToggles",
        @"_TtC11ItemProduct25ItemProductFeatureToggles",
        @"ItemProductFeatureToggles"
    ];

    for (NSString *name in classes) {
        Class cls = NSClassFromString(name);
        EB112HookBool(cls, @"useViewItemExperienceServiceRaptorIOURL");
        EB112HookBool(cls, @"useViewItemExperienceServiceRaptorIOPreviewURL");
    }
}

%ctor {
    @autoreleasepool {
        if (![[[NSBundle mainBundle] bundleIdentifier] isEqualToString:@"com.ebay.iphone"]) return;
        EB112InstallItemV2Hooks();
        for (NSNumber *delay in @[@0.1, @0.25, @0.75, @1.5, @3.0, @5.0, @8.0]) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay.doubleValue * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{ EB112InstallItemV2Hooks(); });
        }
    }
}
