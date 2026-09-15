#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <mach-o/dyld.h>
#import <mach/mach.h>

extern "C" void EB144CallX20Asm(void *fn, void *object);

static BOOL EB148DidAttempt = NO;

static NSString *EB148LogPath(void) {
    NSArray *paths = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
    NSString *dir = paths.firstObject ?: NSTemporaryDirectory();
    return [dir stringByAppendingPathComponent:@"eBayFixer.log"];
}

static void EB148Log(NSString *format, ...) {
    if (!format) return;
    va_list args;
    va_start(args, format);
    NSString *message = [[NSString alloc] initWithFormat:format arguments:args];
    va_end(args);
    if (!message.length) return;

    NSString *path = EB148LogPath();
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

static UIViewController *EB148FindVLPIn(UIViewController *vc) {
    if (!vc) return nil;
    if ([NSStringFromClass([vc class]) containsString:@"HomeVerticalLandingPageViewController"]) return vc;
    if (vc.presentedViewController) {
        UIViewController *f = EB148FindVLPIn(vc.presentedViewController);
        if (f) return f;
    }
    if ([vc isKindOfClass:[UINavigationController class]]) {
        UIViewController *f = EB148FindVLPIn([(UINavigationController *)vc visibleViewController]);
        if (f) return f;
    }
    if ([vc isKindOfClass:[UITabBarController class]]) {
        UIViewController *f = EB148FindVLPIn([(UITabBarController *)vc selectedViewController]);
        if (f) return f;
    }
    for (UIViewController *child in vc.childViewControllers) {
        UIViewController *f = EB148FindVLPIn(child);
        if (f) return f;
    }
    return nil;
}

static UIViewController *EB148FindVLP(void) {
    for (UIWindow *window in [UIApplication sharedApplication].windows) {
        UIViewController *f = EB148FindVLPIn(window.rootViewController);
        if (f) return f;
    }
    return nil;
}

static BOOL EB148Read(uintptr_t address, void *out, vm_size_t length) {
    if (!address || !out || !length) return NO;
    vm_size_t copied = 0;
    kern_return_t kr = vm_read_overwrite(mach_task_self(),
                                         (vm_address_t)address,
                                         length,
                                         (vm_address_t)out,
                                         &copied);
    return kr == KERN_SUCCESS && copied == length;
}

static uintptr_t EB148HomeBase(void) {
    uint32_t count = _dyld_image_count();
    for (uint32_t i = 0; i < count; i++) {
        const char *name = _dyld_get_image_name(i);
        if (!name) continue;
        NSString *path = [NSString stringWithUTF8String:name];
        if ([path hasSuffix:@"/HomePageModule.framework/HomePageModule"])
            return (uintptr_t)_dyld_get_image_header(i);
    }
    return 0;
}

static void EB148ProbeFlags(uintptr_t vm, NSString *phase) {
    uint8_t raw[0x40] = {0};
    if (!EB148Read(vm, raw, sizeof(raw))) {
        EB148Log(@"HOME_REPAIR148 phase=%@ vm_read_failed", phase);
        return;
    }
    EB148Log(@"HOME_REPAIR148 phase=%@ needsRefresh=%u isRefreshing=%u useCase=%u",
             phase, raw[0x38], raw[0x39], raw[0x3a]);
}

static void EB148AttemptRepair(void) {
    if (EB148DidAttempt) return;

    UIViewController *vc = EB148FindVLP();
    if (!vc) {
        EB148Log(@"HOME_REPAIR148 controller_not_found");
        return;
    }

    Class vmClass = NSClassFromString(@"_TtC14HomePageModule28VerticalLandingPageViewModel");
    Class managerClass = NSClassFromString(@"_TtC14HomePageModule31VerticalLandingPageModelManager");
    if (!vmClass || !managerClass) {
        EB148Log(@"HOME_REPAIR148 class_missing vm=%p manager=%p", vmClass, managerClass);
        return;
    }

    Ivar ivar = class_getInstanceVariable([vc class], "viewModel");
    if (!ivar) {
        EB148Log(@"HOME_REPAIR148 viewModel_ivar_missing");
        return;
    }

    ptrdiff_t off = ivar_getOffset(ivar);
    if (off != 0x560) {
        EB148Log(@"HOME_REPAIR148 unexpected_viewModel_offset=0x%tx", off);
        return;
    }

    uintptr_t vmExist[5] = {0};
    memcpy(vmExist, (uint8_t *)(__bridge void *)vc + off, sizeof(vmExist));
    if (!vmExist[0] || vmExist[3] != (uintptr_t)vmClass) {
        EB148Log(@"HOME_REPAIR148 vm_guard_failed obj=0x%llx meta=0x%llx expected=%p",
                 (unsigned long long)vmExist[0], (unsigned long long)vmExist[3], vmClass);
        return;
    }

    uintptr_t vm = vmExist[0];
    uint8_t vmRaw[0x40] = {0};
    if (!EB148Read(vm, vmRaw, sizeof(vmRaw))) {
        EB148Log(@"HOME_REPAIR148 vm_read_failed ptr=0x%llx", (unsigned long long)vm);
        return;
    }

    uintptr_t managerExist[5] = {0};
    memcpy(managerExist, vmRaw + 0x10, sizeof(managerExist));
    if (!managerExist[0] || managerExist[3] != (uintptr_t)managerClass) {
        EB148Log(@"HOME_REPAIR148 manager_guard_failed obj=0x%llx meta=0x%llx expected=%p",
                 (unsigned long long)managerExist[0], (unsigned long long)managerExist[3], managerClass);
        return;
    }

    uint8_t managerRaw[0x28] = {0};
    if (!EB148Read(managerExist[0], managerRaw, sizeof(managerRaw))) {
        EB148Log(@"HOME_REPAIR148 manager_read_failed ptr=0x%llx", (unsigned long long)managerExist[0]);
        return;
    }

    uint8_t needsRefresh = vmRaw[0x38];
    uint8_t isRefreshing = vmRaw[0x39];
    uint8_t useCase = vmRaw[0x3a];
    uint8_t isRetrieving = managerRaw[0x20];

    EB148Log(@"HOME_REPAIR148 guards_ok vm=0x%llx manager=0x%llx needsRefresh=%u isRefreshing=%u useCase=%u isRetrieving=%u",
             (unsigned long long)vm, (unsigned long long)managerExist[0],
             needsRefresh, isRefreshing, useCase, isRetrieving);

    if (isRefreshing || isRetrieving || useCase > 2) {
        EB148Log(@"HOME_REPAIR148 unsafe_state_skip");
        return;
    }

    uintptr_t base = EB148HomeBase();
    if (!base) {
        EB148Log(@"HOME_REPAIR148 image_not_found");
        return;
    }

    EB148DidAttempt = YES;

    // 6.96 VerticalLandingPageViewModel setup/bind routine.
    EB148Log(@"HOME_REPAIR148 calling_setup base=0x%llx fn=0xf462c",
             (unsigned long long)base);
    EB144CallX20Asm((void *)(base + 0xF462C), (void *)vm);
    EB148ProbeFlags(vm, @"after_setup");

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.35 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        uint8_t verify[0x40] = {0};
        if (!EB148Read(vm, verify, sizeof(verify))) {
            EB148Log(@"HOME_REPAIR148 prefetch_read_failed");
            return;
        }
        if (verify[0x39] != 0 || verify[0x3a] > 2) {
            EB148Log(@"HOME_REPAIR148 prefetch_guard_failed isRefreshing=%u useCase=%u", verify[0x39], verify[0x3a]);
            return;
        }

        EB148Log(@"HOME_REPAIR148 calling_fetch fn=0xf46c4");
        EB144CallX20Asm((void *)(base + 0xF46C4), (void *)vm);
        EB148ProbeFlags(vm, @"after_fetch");

        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            EB148ProbeFlags(vm, @"post_2s");
            id sections = nil;
            @try { sections = [vc valueForKey:@"sectionModels"]; } @catch (__unused NSException *e) {}
            NSUInteger count = [sections respondsToSelector:@selector(count)] ? [sections count] : 0;
            EB148Log(@"HOME_REPAIR148 post_2s sectionModels=%@ count=%lu",
                     sections ? NSStringFromClass([sections class]) : @"nil", (unsigned long)count);
        });
    });
}

%ctor {
    if (![[[NSBundle mainBundle] bundleIdentifier] isEqualToString:@"com.ebay.iphone"]) return;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        EB148AttemptRepair();
    });
}
