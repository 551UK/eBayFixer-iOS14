#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <substrate.h>
#import "Prefs.h"

static NSMutableSet *EBHomeInstalledHooks(void) {
    static NSMutableSet *set;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{ set = [NSMutableSet set]; });
    return set;
}

static BOOL EBHomeYes(id self, SEL _cmd) { return YES; }
static BOOL EBHomeNo(id self, SEL _cmd) { return NO; }

static void EBHomeHookBool(Class cls, NSString *selectorName, IMP replacement) {
    if (!cls || !selectorName.length || !replacement) return;
    SEL selector = NSSelectorFromString(selectorName);
    if (!class_getInstanceMethod(cls, selector)) return;

    NSString *key = [NSString stringWithFormat:@"%@::%@", NSStringFromClass(cls), selectorName];
    @synchronized (EBHomeInstalledHooks()) {
        if ([EBHomeInstalledHooks() containsObject:key]) return;
        MSHookMessageEx(cls, selector, replacement, NULL);
        [EBHomeInstalledHooks() addObject:key];
    }
}

static BOOL EBHomeSetBoolIvar(id object, const char *name, BOOL value) {
    if (!object || !name) return NO;
    Ivar ivar = class_getInstanceVariable([object class], name);
    if (!ivar) return NO;
    const char *type = ivar_getTypeEncoding(ivar);
    if (!type || (type[0] != 'B' && type[0] != 'c')) return NO;
    uint8_t *storage = ((uint8_t *)(__bridge void *)object) + ivar_getOffset(ivar);
    *storage = value ? 1 : 0;
    return YES;
}

static id (*EBHomeOrigToggleInit)(id, SEL) = NULL;
static BOOL EBHomeToggleInitHooked = NO;

static id EBHomeToggleInit(id self, SEL _cmd) {
    id result = EBHomeOrigToggleInit ? EBHomeOrigToggleInit(self, _cmd) : self;
    EBHomeSetBoolIvar(result, "_vlpF90", YES);
    EBHomeSetBoolIvar(result, "_vlpF90KillSwitch", NO);
    return result;
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
        EBHomeHookBool(cls, @"vlpF90", (IMP)EBHomeYes);
        EBHomeHookBool(cls, @"vlpF90KillSwitch", (IMP)EBHomeNo);
        EBHomeHookBool(cls, @"preprodServiceVLPHomepage", (IMP)EBHomeNo);
        EBHomeHookBool(cls, @"preprodServiceVLPSegmentation", (IMP)EBHomeNo);
    }

    if (!EBHomeToggleInitHooked) {
        Class cls = NSClassFromString(@"_TtC14HomePageModule26ObjCHomePageFeatureToggles");
        Method method = cls ? class_getInstanceMethod(cls, @selector(init)) : NULL;
        if (method) {
            MSHookMessageEx(cls, @selector(init), (IMP)EBHomeToggleInit, (IMP *)&EBHomeOrigToggleInit);
            EBHomeToggleInitHooked = YES;
        }
    }
}

%ctor {
    @autoreleasepool {
        if (![[[NSBundle mainBundle] bundleIdentifier] isEqualToString:@"com.ebay.iphone"] || !EBPrefsEnabled()) return;
        EBInstallHomeCompat();
        for (NSNumber *delay in @[@0.1, @0.5, @1.0, @2.0, @4.0]) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay.doubleValue * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{ EBInstallHomeCompat(); });
        }
    }
}
