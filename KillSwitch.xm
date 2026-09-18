#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <mach-o/dyld.h>
#import <substrate.h>
#import <string.h>
#import "Prefs.h"

static NSString *const EBKSTargetBundleID = @"com.ebay.iphone";

static BOOL EBKillSwitchOff(id self, SEL _cmd) { return NO; }

static NSMutableSet *EBKSHookedMethods(void) {
    static NSMutableSet *set;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{ set = [NSMutableSet set]; });
    return set;
}

static BOOL EBKSIsBoolMethod(Method method) {
    if (!method) return NO;
    const char *types = method_getTypeEncoding(method);
    return types && (types[0] == 'B' || types[0] == 'c');
}

static void EBKSHookTarget(Class target, NSString *className, NSString *kind) {
    if (!target) return;

    SEL selector = NSSelectorFromString(@"killswitch");
    Method method = class_getInstanceMethod(target, selector);
    if (!EBKSIsBoolMethod(method)) return;

    NSString *key = [NSString stringWithFormat:@"%@:%@", kind, className ?: @""];
    @synchronized (EBKSHookedMethods()) {
        if ([EBKSHookedMethods() containsObject:key]) return;
        MSHookMessageEx(target, selector, (IMP)EBKillSwitchOff, NULL);
        [EBKSHookedMethods() addObject:key];
    }
}

static BOOL EBKSRelevantClassName(const char *name) {
    if (!name || !name[0]) return NO;
    return strstr(name, "FoundationsAppFeatures") != NULL ||
           strstr(name, "KillSwitch") != NULL ||
           strstr(name, "ModuleLinker") != NULL;
}

static BOOL EBKSIsEBayImagePath(const char *path) {
    if (!path || !path[0]) return NO;

    // Only inspect code shipped inside the eBay app bundle. The old scanner
    // walked every Objective-C/Swift class in the process, including system
    // and third-party frameworks, which could force Swift metadata to realize
    // during startup on iOS 14.7.1.
    return strstr(path, "/eBay.app/") != NULL ||
           strstr(path, "/eBay.app/eBay") != NULL;
}

static void EBKSScanImage(const char *imagePath) {
    if (!EBKSIsEBayImagePath(imagePath)) return;

    unsigned int count = 0;
    const char **names = objc_copyClassNamesForImage(imagePath, &count);
    if (!names || count == 0) {
        if (names) free(names);
        return;
    }

    for (unsigned int i = 0; i < count; i++) {
        const char *className = names[i];
        if (!EBKSRelevantClassName(className)) continue;

        // Look up only the already-known matching class. This preserves the
        // original kill-switch bypass without asking the Swift runtime to
        // stringify/realize every loaded class in the process.
        Class cls = objc_lookUpClass(className);
        if (!cls) continue;

        NSString *name = [NSString stringWithUTF8String:className] ?: @"";
        EBKSHookTarget(cls, name, @"instance");

        Class meta = object_getClass(cls);
        if (meta) EBKSHookTarget(meta, name, @"class");
    }

    free(names);
}

static void EBKSScanLoadedImages(void) {
    uint32_t count = _dyld_image_count();
    for (uint32_t i = 0; i < count; i++) {
        const char *path = _dyld_get_image_name(i);
        EBKSScanImage(path);
    }
}

static void EBKSScheduleScans(void) {
    // Same purpose and repeated coverage as before, but the scan is now
    // metadata-only and restricted to eBay-owned images.
    for (NSNumber *delay in @[@0.0, @0.10, @0.25, @0.50, @1.0, @2.5, @5.0, @8.0]) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                                     (int64_t)(delay.doubleValue * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            if (EBPrefsEnabled()) EBKSScanLoadedImages();
        });
    }
}

%ctor {
    @autoreleasepool {
        if (![[[NSBundle mainBundle] bundleIdentifier] isEqualToString:EBKSTargetBundleID] ||
            !EBPrefsEnabled()) return;

        // Do not enumerate or stringify the live Objective-C/Swift class list
        // from inside dyld initialization. The actual killswitch hook remains
        // exactly the same; only discovery is made safe for iOS 14.7.1.
        EBKSScheduleScans();
    }
}
