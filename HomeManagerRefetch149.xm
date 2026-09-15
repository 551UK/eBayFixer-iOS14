#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <mach-o/dyld.h>
#import <mach/mach.h>

extern "C" void EB144CallX20Asm(void *fn, void *object);
extern "C" void EB149CallX20W0Asm(void *fn, void *object, uint32_t arg0);

static BOOL EB149DidAttempt = NO;

static NSString *EB149LogPath(void) {
    NSArray *paths = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
    NSString *dir = paths.firstObject ?: NSTemporaryDirectory();
    return [dir stringByAppendingPathComponent:@"eBayFixer.log"];
}

static void EB149Log(NSString *format, ...) {
    if (!format) return;
    va_list args;
    va_start(args, format);
    NSString *message = [[NSString alloc] initWithFormat:format arguments:args];
    va_end(args);
    if (!message.length) return;
    NSString *path = EB149LogPath();
    if (![[NSFileManager defaultManager] fileExistsAtPath:path])
        [[NSFileManager defaultManager] createFileAtPath:path contents:nil attributes:nil];
    NSFileHandle *h = [NSFileHandle fileHandleForWritingAtPath:path];
    if (!h) return;
    NSString *line = [NSString stringWithFormat:@"%@ %@\n", [NSDate date], message];
    @try {
        [h seekToEndOfFile];
        [h writeData:[line dataUsingEncoding:NSUTF8StringEncoding]];
        [h closeFile];
    } @catch (__unused NSException *e) {}
}

static UIViewController *EB149FindVLPIn(UIViewController *vc) {
    if (!vc) return nil;
    if ([NSStringFromClass([vc class]) containsString:@"HomeVerticalLandingPageViewController"]) return vc;
    if (vc.presentedViewController) {
        UIViewController *f = EB149FindVLPIn(vc.presentedViewController);
        if (f) return f;
    }
    if ([vc isKindOfClass:[UINavigationController class]]) {
        UIViewController *f = EB149FindVLPIn([(UINavigationController *)vc visibleViewController]);
        if (f) return f;
    }
    if ([vc isKindOfClass:[UITabBarController class]]) {
        UIViewController *f = EB149FindVLPIn([(UITabBarController *)vc selectedViewController]);
        if (f) return f;
    }
    for (UIViewController *child in vc.childViewControllers) {
        UIViewController *f = EB149FindVLPIn(child);
        if (f) return f;
    }
    return nil;
}

static UIViewController *EB149FindVLP(void) {
    for (UIWindow *window in [UIApplication sharedApplication].windows) {
        UIViewController *f = EB149FindVLPIn(window.rootViewController);
        if (f) return f;
    }
    return nil;
}

static BOOL EB149Read(uintptr_t address, void *out, vm_size_t length) {
    if (!address || !out || !length) return NO;
    vm_size_t copied = 0;
    kern_return_t kr = vm_read_overwrite(mach_task_self(), (vm_address_t)address, length,
                                         (vm_address_t)out, &copied);
    return kr == KERN_SUCCESS && copied == length;
}

static uintptr_t EB149HomeBase(void) {
    for (uint32_t i = 0; i < _dyld_image_count(); i++) {
        const char *name = _dyld_get_image_name(i);
        if (!name) continue;
        NSString *path = [NSString stringWithUTF8String:name];
        if ([path hasSuffix:@"/HomePageModule.framework/HomePageModule"])
            return (uintptr_t)_dyld_get_image_header(i);
    }
    return 0;
}

static void EB149Snapshot(UIViewController *vc, uintptr_t vm, uintptr_t manager, NSString *phase) {
    uint8_t vr[0xB0] = {0};
    uint8_t mr[0xA8] = {0};
    BOOL vok = EB149Read(vm, vr, sizeof(vr));
    BOOL mok = EB149Read(manager, mr, sizeof(mr));
    id sections = nil;
    @try { sections = [vc valueForKey:@"sectionModels"]; } @catch (__unused NSException *e) {}
    NSUInteger count = [sections respondsToSelector:@selector(count)] ? [sections count] : 0;
    if (!vok || !mok) {
        EB149Log(@"HOME_MANAGER149 phase=%@ read_failed vm=%d manager=%d sections=%@ count=%lu",
                 phase, vok, mok, sections ? NSStringFromClass([sections class]) : @"nil", (unsigned long)count);
        return;
    }
    uintptr_t loading0 = 0, sections0 = 0, error0 = 0;
    memcpy(&loading0, vr + 0x58, sizeof(loading0));
    memcpy(&sections0, vr + 0x68, sizeof(sections0));
    memcpy(&error0, vr + 0x90, sizeof(error0));
    EB149Log(@"HOME_MANAGER149 phase=%@ needs=%u refreshing=%u useCase=%u retrieving=%u pubLoading0=0x%llx pubSections0=0x%llx pubError0=0x%llx sectionModels=%@ count=%lu",
             phase, vr[0x38], vr[0x39], vr[0x3a], mr[0x20],
             (unsigned long long)loading0, (unsigned long long)sections0, (unsigned long long)error0,
             sections ? NSStringFromClass([sections class]) : @"nil", (unsigned long)count);
}

static void EB149Attempt(void) {
    if (EB149DidAttempt) return;
    UIViewController *vc = EB149FindVLP();
    if (!vc) { EB149Log(@"HOME_MANAGER149 controller_not_found"); return; }

    Class vmClass = NSClassFromString(@"_TtC14HomePageModule28VerticalLandingPageViewModel");
    Class managerClass = NSClassFromString(@"_TtC14HomePageModule31VerticalLandingPageModelManager");
    if (!vmClass || !managerClass) { EB149Log(@"HOME_MANAGER149 class_missing"); return; }

    Ivar ivar = class_getInstanceVariable([vc class], "viewModel");
    if (!ivar || ivar_getOffset(ivar) != 0x560) {
        EB149Log(@"HOME_MANAGER149 viewModel_guard_failed off=0x%tx", ivar ? ivar_getOffset(ivar) : -1);
        return;
    }

    uintptr_t vme[5] = {0};
    memcpy(vme, (uint8_t *)(__bridge void *)vc + 0x560, sizeof(vme));
    if (!vme[0] || vme[3] != (uintptr_t)vmClass) {
        EB149Log(@"HOME_MANAGER149 vm_meta_guard_failed obj=0x%llx meta=0x%llx expected=%p",
                 (unsigned long long)vme[0], (unsigned long long)vme[3], vmClass);
        return;
    }

    uint8_t vr[0x40] = {0};
    if (!EB149Read(vme[0], vr, sizeof(vr))) { EB149Log(@"HOME_MANAGER149 vm_read_failed"); return; }
    uintptr_t me[5] = {0};
    memcpy(me, vr + 0x10, sizeof(me));
    if (!me[0] || me[3] != (uintptr_t)managerClass) {
        EB149Log(@"HOME_MANAGER149 manager_meta_guard_failed obj=0x%llx meta=0x%llx expected=%p",
                 (unsigned long long)me[0], (unsigned long long)me[3], managerClass);
        return;
    }

    uintptr_t base = EB149HomeBase();
    if (!base) { EB149Log(@"HOME_MANAGER149 image_not_found"); return; }

    uint8_t useCase = vr[0x3a];
    if (useCase > 1) { EB149Log(@"HOME_MANAGER149 unsupported_useCase=%u", useCase); return; }

    uintptr_t vmPtr = vme[0];
    uintptr_t managerPtr = me[0];
    EB149DidAttempt = YES;
    EB149Log(@"HOME_MANAGER149 guards_ok vm=0x%llx manager=0x%llx base=0x%llx useCase=%u",
             (unsigned long long)vmPtr, (unsigned long long)managerPtr,
             (unsigned long long)base, useCase);

    EB149Snapshot(vc, vmPtr, managerPtr, @"before_setup");

    // Bind the ViewModel to the manager's publisher using the exact 6.96 routine.
    EB144CallX20Asm((void *)(base + 0xF462C), (void *)vmPtr);
    EB149Snapshot(vc, vmPtr, managerPtr, @"after_setup");

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.30 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        uint8_t mr[0x28] = {0};
        if (!EB149Read(managerPtr, mr, sizeof(mr))) {
            EB149Log(@"HOME_MANAGER149 prefetch_manager_read_failed");
            return;
        }
        if (mr[0x20] != 0) {
            EB149Log(@"HOME_MANAGER149 prefetch_skip retrieving=%u", mr[0x20]);
            return;
        }

        // Bypass ViewModel's HomeHotSwapper early-return and invoke the manager's native fetch directly.
        EB149Log(@"HOME_MANAGER149 calling_manager_fetch fn=0xd82f4 useCase=%u", useCase);
        EB149CallX20W0Asm((void *)(base + 0xD82F4), (void *)managerPtr, (uint32_t)(useCase & 1));
        EB149Snapshot(vc, vmPtr, managerPtr, @"after_manager_fetch");

        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.20 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            EB149Snapshot(vc, vmPtr, managerPtr, @"plus_200ms");
        });
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            EB149Snapshot(vc, vmPtr, managerPtr, @"plus_1.5s");
        });
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(4.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            EB149Snapshot(vc, vmPtr, managerPtr, @"plus_4s");
        });
    });
}

%ctor {
    if (![[[NSBundle mainBundle] bundleIdentifier] isEqualToString:@"com.ebay.iphone"]) return;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        EB149Attempt();
    });
}
