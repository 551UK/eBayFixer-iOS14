#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <dlfcn.h>
#import <mach-o/dyld.h>
#import <substrate.h>
#import "Prefs.h"

static const uintptr_t EB128InitialRouteOffset = 0x38BD8;
static const uintptr_t EB128StateRouteOffset = 0x38F08;
static BOOL EB128Finished = NO;

static BOOL EB128IsHomeImagePath(const char *path) {
    if (!path) return NO;
    return strstr(path, "HomePageModule.framework/HomePageModule") != NULL ||
           strstr(path, "/HomePageModule.framework/") != NULL;
}

static void *EB128HomeImageBase(void) {
    for (uint32_t i = 0; i < _dyld_image_count(); i++) {
        const char *name = _dyld_get_image_name(i);
        if (!EB128IsHomeImagePath(name)) continue;
        const struct mach_header *header = _dyld_get_image_header(i);
        if (header) return (void *)header;
    }

    Class cls = objc_getClass("_TtC14HomePageModule37HomeVerticalLandingPageViewController");
    if (!cls) return NULL;
    for (NSString *selectorName in @[@"shouldShowTitleImageView", @"setupTitleImageView:", @"viewWillAppear:", @"viewDidLayoutSubviews", @"viewDidDisappear:"]) {
        Method method = class_getInstanceMethod(cls, NSSelectorFromString(selectorName));
        if (!method) continue;
        IMP imp = method_getImplementation(method);
        if (!imp) continue;
        Dl_info info = {0};
        if (dladdr((const void *)imp, &info) != 0 && info.dli_fbase && EB128IsHomeImagePath(info.dli_fname))
            return info.dli_fbase;
    }
    return NULL;
}

static BOOL EB128Patch4(uint8_t *base, uintptr_t offset, const uint8_t expected[4], const uint8_t replacement[4]) {
    uint8_t *target = base + offset;
    if (memcmp(target, replacement, 4) == 0) return YES;
    if (memcmp(target, expected, 4) != 0) return NO;
    MSHookMemory(target, replacement, 4);
    return memcmp(target, replacement, 4) == 0;
}

static void EB128TryPatch(void) {
    if (EB128Finished || !EBPrefsEnabled()) return;
    uint8_t *base = (uint8_t *)EB128HomeImageBase();
    if (!base) return;

    const uint8_t nop[4] = {0x1F, 0x20, 0x03, 0xD5};
    const uint8_t initialExpected[4] = {0x54, 0x01, 0x00, 0x36};
    const uint8_t stateExpected[4] = {0x94, 0x00, 0x00, 0x36};

    BOOL initial = EB128Patch4(base, EB128InitialRouteOffset, initialExpected, nop);
    BOOL state = EB128Patch4(base, EB128StateRouteOffset, stateExpected, nop);
    EB128Finished = initial && state;
}

%ctor {
    @autoreleasepool {
        if (![[[NSBundle mainBundle] bundleIdentifier] isEqualToString:@"com.ebay.iphone"] || !EBPrefsEnabled()) return;
        EB128TryPatch();
        for (NSNumber *delay in @[@0.0, @0.005, @0.01, @0.02, @0.04, @0.08, @0.15, @0.30, @0.60, @1.0]) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay.doubleValue * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ EB128TryPatch(); });
        }
    }
}
