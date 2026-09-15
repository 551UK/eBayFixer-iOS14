#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <mach-o/dyld.h>
#import <mach/mach.h>
#import "Prefs.h"

extern "C" void EB144CallX20Asm(void *fn, void *object);
extern "C" void EB149CallX20W0Asm(void *fn, void *object, uint32_t arg0);

static BOOL EBFixDidAttempt = NO;

static UIViewController *EBFixFindVLPIn(UIViewController *vc) {
    if (!vc) return nil;
    if ([NSStringFromClass([vc class]) containsString:@"HomeVerticalLandingPageViewController"]) return vc;
    if (vc.presentedViewController) {
        UIViewController *found = EBFixFindVLPIn(vc.presentedViewController);
        if (found) return found;
    }
    if ([vc isKindOfClass:[UINavigationController class]]) {
        UIViewController *found = EBFixFindVLPIn([(UINavigationController *)vc visibleViewController]);
        if (found) return found;
    }
    if ([vc isKindOfClass:[UITabBarController class]]) {
        UIViewController *found = EBFixFindVLPIn([(UITabBarController *)vc selectedViewController]);
        if (found) return found;
    }
    for (UIViewController *child in vc.childViewControllers) {
        UIViewController *found = EBFixFindVLPIn(child);
        if (found) return found;
    }
    return nil;
}

static UIViewController *EBFixFindVLP(void) {
    for (UIWindow *window in [UIApplication sharedApplication].windows) {
        UIViewController *found = EBFixFindVLPIn(window.rootViewController);
        if (found) return found;
    }
    return nil;
}

static BOOL EBFixRead(uintptr_t address, void *out, vm_size_t length) {
    if (!address || !out || !length) return NO;
    vm_size_t copied = 0;
    kern_return_t kr = vm_read_overwrite(mach_task_self(), (vm_address_t)address, length,
                                         (vm_address_t)out, &copied);
    return kr == KERN_SUCCESS && copied == length;
}

static uintptr_t EBFixHomeBase(void) {
    for (uint32_t i = 0; i < _dyld_image_count(); i++) {
        const char *name = _dyld_get_image_name(i);
        if (!name) continue;
        NSString *path = [NSString stringWithUTF8String:name];
        if ([path hasSuffix:@"/HomePageModule.framework/HomePageModule"])
            return (uintptr_t)_dyld_get_image_header(i);
    }
    return 0;
}

static void EBFixAttempt(void) {
    if (EBFixDidAttempt || !EBPrefsEnabled()) return;

    UIViewController *vc = EBFixFindVLP();
    if (!vc) return;

    Class vmClass = NSClassFromString(@"_TtC14HomePageModule28VerticalLandingPageViewModel");
    Class managerClass = NSClassFromString(@"_TtC14HomePageModule31VerticalLandingPageModelManager");
    if (!vmClass || !managerClass) return;

    Ivar ivar = class_getInstanceVariable([vc class], "viewModel");
    if (!ivar || ivar_getOffset(ivar) != 0x560) return;

    uintptr_t vmExist[5] = {0};
    memcpy(vmExist, (uint8_t *)(__bridge void *)vc + 0x560, sizeof(vmExist));
    if (!vmExist[0] || vmExist[3] != (uintptr_t)vmClass) return;

    uintptr_t vm = vmExist[0];
    uint8_t vmRaw[0x40] = {0};
    if (!EBFixRead(vm, vmRaw, sizeof(vmRaw))) return;

    uintptr_t managerExist[5] = {0};
    memcpy(managerExist, vmRaw + 0x10, sizeof(managerExist));
    if (!managerExist[0] || managerExist[3] != (uintptr_t)managerClass) return;

    uintptr_t manager = managerExist[0];
    uintptr_t base = EBFixHomeBase();
    if (!base) return;

    uint8_t useCase = vmRaw[0x3a];
    if (useCase > 1) return;

    EBFixDidAttempt = YES;

    // Rebind the 6.96 VLP ViewModel to the manager publisher.
    EB144CallX20Asm((void *)(base + 0xF462C), (void *)vm);

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.30 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        if (!EBPrefsEnabled()) return;
        uint8_t managerRaw[0x28] = {0};
        if (!EBFixRead(manager, managerRaw, sizeof(managerRaw))) return;
        if (managerRaw[0x20] != 0) return;

        // Bypass the stale HomeHotSwapper gate and call the native 6.96 manager fetch directly.
        EB149CallX20W0Asm((void *)(base + 0xD82F4), (void *)manager, (uint32_t)(useCase & 1));
    });
}

%ctor {
    if (![[[NSBundle mainBundle] bundleIdentifier] isEqualToString:@"com.ebay.iphone"]) return;
    if (!EBPrefsEnabled()) return;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        EBFixAttempt();
    });
}
