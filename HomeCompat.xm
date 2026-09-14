#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <substrate.h>

static NSString *const EBHomeURL = @"https://api.ebay.com/experience/vertical_landing/v1/get_homepage";

static NSMutableSet *EBHomeInstalledHooks(void) {
    static NSMutableSet *set;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{ set = [NSMutableSet set]; });
    return set;
}

static BOOL EBHomeYes(id self, SEL _cmd) { return YES; }
static BOOL EBHomeNo(id self, SEL _cmd) { return NO; }
static id EBHomeBaseURL(id self, SEL _cmd) { return EBHomeURL; }

static BOOL EBHomeHook(Class cls, NSString *selectorName, IMP replacement) {
    if (!cls || !selectorName.length || !replacement) return NO;
    SEL selector = NSSelectorFromString(selectorName);
    if (!class_getInstanceMethod(cls, selector)) return NO;

    NSString *key = [NSString stringWithFormat:@"%@::%@", NSStringFromClass(cls), selectorName];
    @synchronized (EBHomeInstalledHooks()) {
        if ([EBHomeInstalledHooks() containsObject:key]) return YES;
        MSHookMessageEx(cls, selector, replacement, NULL);
        [EBHomeInstalledHooks() addObject:key];
    }
    return YES;
}

static void EBInstallHomeCompat(void) {
    NSArray *toggleClasses = @[
        @"_TtC14HomePageModule26ObjCHomePageFeatureToggles",
        @"ObjCHomePageFeatureToggles",
        @"_TtC14HomePageModule22HomePageFeatureToggles",
        @"HomePageFeatureToggles"
    ];

    for (NSString *name in toggleClasses) {
        Class cls = NSClassFromString(name);
        EBHomeHook(cls, @"vlpF90", (IMP)EBHomeYes);
        EBHomeHook(cls, @"vlpF90KillSwitch", (IMP)EBHomeNo);
        EBHomeHook(cls, @"preprodServiceVLPHomepage", (IMP)EBHomeNo);
        EBHomeHook(cls, @"preprodServiceVLPSegmentation", (IMP)EBHomeNo);
    }

    // The old app can still decide the user is not in the F90 Home cohort even
    // when vlpF90 is enabled. Force the actual request and segmentation result.
    Class request = NSClassFromString(@"_TtC14HomePageModule30HomeVerticalLandingPageRequest");
    EBHomeHook(request, @"isF90User", (IMP)EBHomeYes);
    EBHomeHook(request, @"baseURLString", (IMP)EBHomeBaseURL);

    Class flag = NSClassFromString(@"_TtC14HomePageModule39HomeVerticalLandingPageSegmentationFlag");
    EBHomeHook(flag, @"isF90UserValue", (IMP)EBHomeYes);
}

%ctor {
    @autoreleasepool {
        if (![[[NSBundle mainBundle] bundleIdentifier] isEqualToString:@"com.ebay.iphone"]) return;
        EBInstallHomeCompat();
        for (NSNumber *delay in @[@0.1, @0.25, @0.75, @1.5, @3.0, @5.0]) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay.doubleValue * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{ EBInstallHomeCompat(); });
        }
    }
}
