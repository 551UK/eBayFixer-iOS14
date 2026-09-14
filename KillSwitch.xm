#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <substrate.h>

static NSString *const EBKSTargetBundleID = @"com.ebay.iphone";

static BOOL EBKillSwitchOff(id self, SEL _cmd) {
    return NO;
}

static NSMutableSet *EBKSHookedMethods(void) {
    static NSMutableSet *set;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        set = [NSMutableSet set];
    });
    return set;
}

static BOOL EBKSIsBoolMethod(Method method) {
    if (!method) return NO;
    const char *types = method_getTypeEncoding(method);
    if (!types || !types[0]) return NO;
    return types[0] == 'B' || types[0] == 'c';
}

static BOOL EBKSHookTarget(Class target, NSString *className, NSString *kind) {
    if (!target) return NO;

    SEL selector = NSSelectorFromString(@"killswitch");
    Method method = class_getInstanceMethod(target, selector);
    if (!EBKSIsBoolMethod(method)) return NO;

    NSString *key = [NSString stringWithFormat:@"%@:%@", kind, className];
    @synchronized (EBKSHookedMethods()) {
        if ([EBKSHookedMethods() containsObject:key]) return YES;
        MSHookMessageEx(target, selector, (IMP)EBKillSwitchOff, NULL);
        [EBKSHookedMethods() addObject:key];
    }

    NSLog(@"[eBayFixer] Forced %@ %@.killswitch -> NO", kind, className);
    return YES;
}

static void EBKSScan(void) {
    int count = objc_getClassList(NULL, 0);
    if (count <= 0) return;

    Class *classes = (__unsafe_unretained Class *)calloc((size_t)count, sizeof(Class));
    if (!classes) return;
    count = objc_getClassList(classes, count);

    for (int i = 0; i < count; i++) {
        Class cls = classes[i];
        NSString *name = NSStringFromClass(cls);
        if (name.length == 0) continue;

        // The supplied 6.96.0 IPA places the expiry gate in
        // FoundationsAppFeatures/KillSwitchCoordinator.swift. Restrict the
        // generic selector scan to eBay's relevant modules so unrelated SDKs
        // are never touched.
        BOOL relevant = [name containsString:@"FoundationsAppFeatures"] ||
                        [name containsString:@"KillSwitch"] ||
                        [name containsString:@"ModuleLinker"];
        if (!relevant) continue;

        EBKSHookTarget(cls, name, @"instance");
        EBKSHookTarget(object_getClass(cls), name, @"class");
    }

    free(classes);
}

%ctor {
    @autoreleasepool {
        if (![[[NSBundle mainBundle] bundleIdentifier] isEqualToString:EBKSTargetBundleID]) return;

        EBKSScan();
        for (NSNumber *delay in @[@0.25, @1.0, @2.5, @5.0, @8.0]) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay.doubleValue * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{
                EBKSScan();
            });
        }
    }
}
