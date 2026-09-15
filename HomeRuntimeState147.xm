#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <mach/mach.h>

static NSString *EB147LogPath(void) {
    NSArray *paths = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
    NSString *dir = paths.firstObject ?: NSTemporaryDirectory();
    return [dir stringByAppendingPathComponent:@"eBayFixer.log"];
}

static void EB147Log(NSString *format, ...) {
    if (!format) return;
    va_list args;
    va_start(args, format);
    NSString *message = [[NSString alloc] initWithFormat:format arguments:args];
    va_end(args);
    if (!message.length) return;
    NSString *path = EB147LogPath();
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

static UIViewController *EB147FindVLPIn(UIViewController *vc) {
    if (!vc) return nil;
    if ([NSStringFromClass([vc class]) containsString:@"HomeVerticalLandingPageViewController"]) return vc;
    if (vc.presentedViewController) {
        UIViewController *f = EB147FindVLPIn(vc.presentedViewController);
        if (f) return f;
    }
    if ([vc isKindOfClass:[UINavigationController class]]) {
        UIViewController *f = EB147FindVLPIn([(UINavigationController *)vc visibleViewController]);
        if (f) return f;
    }
    if ([vc isKindOfClass:[UITabBarController class]]) {
        UIViewController *f = EB147FindVLPIn([(UITabBarController *)vc selectedViewController]);
        if (f) return f;
    }
    for (UIViewController *child in vc.childViewControllers) {
        UIViewController *f = EB147FindVLPIn(child);
        if (f) return f;
    }
    return nil;
}

static UIViewController *EB147FindVLP(void) {
    for (UIWindow *window in [UIApplication sharedApplication].windows) {
        UIViewController *f = EB147FindVLPIn(window.rootViewController);
        if (f) return f;
    }
    return nil;
}

static BOOL EB147Read(uintptr_t address, void *out, vm_size_t length) {
    if (!address || !out || !length) return NO;
    vm_size_t copied = 0;
    kern_return_t kr = vm_read_overwrite(mach_task_self(),
                                         (vm_address_t)address,
                                         length,
                                         (vm_address_t)out,
                                         &copied);
    return kr == KERN_SUCCESS && copied == length;
}

static BOOL EB147Interesting(NSString *name) {
    NSString *s = name.lowercaseString;
    return [s containsString:@"model"] || [s containsString:@"manager"] ||
           [s containsString:@"load"] || [s containsString:@"fetch"] ||
           [s containsString:@"refresh"] || [s containsString:@"error"] ||
           [s containsString:@"retriev"] || [s containsString:@"publish"] ||
           [s containsString:@"subject"] || [s containsString:@"cancel"];
}

static void EB147DumpClass(Class cls, NSString *label) {
    if (!cls) {
        EB147Log(@"HOME_STATE147 class_missing label=%@", label);
        return;
    }
    EB147Log(@"HOME_STATE147 class label=%@ name=%@ ptr=%p size=%zu super=%@",
             label, NSStringFromClass(cls), cls, class_getInstanceSize(cls),
             class_getSuperclass(cls) ? NSStringFromClass(class_getSuperclass(cls)) : @"nil");

    unsigned int count = 0;
    Ivar *ivars = class_copyIvarList(cls, &count);
    for (unsigned int i = 0; i < count; i++) {
        const char *n = ivar_getName(ivars[i]);
        const char *t = ivar_getTypeEncoding(ivars[i]);
        EB147Log(@"HOME_STATE147 ivar label=%@ name=%s type=%s off=0x%tx",
                 label, n ?: "?", t ?: "?", ivar_getOffset(ivars[i]));
    }
    if (ivars) free(ivars);

    Method *methods = class_copyMethodList(cls, &count);
    for (unsigned int i = 0; i < count; i++) {
        NSString *n = NSStringFromSelector(method_getName(methods[i]));
        if (EB147Interesting(n)) {
            EB147Log(@"HOME_STATE147 method label=%@ name=%@ types=%s",
                     label, n, method_getTypeEncoding(methods[i]) ?: "?");
        }
    }
    if (methods) free(methods);
}

static void EB147Probe(NSString *phase, BOOL dumpClasses) {
    UIViewController *vc = EB147FindVLP();
    if (!vc) {
        EB147Log(@"HOME_STATE147 phase=%@ controller=not_found", phase);
        return;
    }

    Class vmClass = NSClassFromString(@"_TtC14HomePageModule28VerticalLandingPageViewModel");
    Class managerClass = NSClassFromString(@"_TtC14HomePageModule31VerticalLandingPageModelManager");
    Class flowClass = NSClassFromString(@"_TtC14HomePageModule37HomeVerticalLandingPageFlowController");

    if (dumpClasses) {
        EB147DumpClass(vmClass, @"viewModel");
        EB147DumpClass(managerClass, @"manager");
        EB147DumpClass(flowClass, @"flow");
    }

    Ivar vmIvar = class_getInstanceVariable([vc class], "viewModel");
    if (!vmIvar) {
        EB147Log(@"HOME_STATE147 phase=%@ viewModel_ivar_missing", phase);
        return;
    }

    ptrdiff_t off = ivar_getOffset(vmIvar);
    size_t vcSize = class_getInstanceSize([vc class]);
    if (off < 0 || (size_t)off + 0x28 > vcSize) {
        EB147Log(@"HOME_STATE147 phase=%@ bad_viewModel_offset=0x%tx vcSize=%zu", phase, off, vcSize);
        return;
    }

    uintptr_t words[5] = {0};
    memcpy(words, (uint8_t *)(__bridge void *)vc + off, sizeof(words));
    EB147Log(@"HOME_STATE147 phase=%@ viewModelExist off=0x%tx w0=0x%llx w1=0x%llx w2=0x%llx meta=0x%llx witness=0x%llx vmClass=%p metaMatch=%d",
             phase, off,
             (unsigned long long)words[0], (unsigned long long)words[1],
             (unsigned long long)words[2], (unsigned long long)words[3],
             (unsigned long long)words[4], vmClass, (vmClass && words[3] == (uintptr_t)vmClass));

    if (!vmClass || words[3] != (uintptr_t)vmClass || !words[0]) return;

    uint8_t vmRaw[0x80] = {0};
    if (!EB147Read(words[0], vmRaw, sizeof(vmRaw))) {
        EB147Log(@"HOME_STATE147 phase=%@ vm_read_failed ptr=0x%llx", phase, (unsigned long long)words[0]);
        return;
    }

    uintptr_t managerWords[5] = {0};
    memcpy(managerWords, vmRaw + 0x10, sizeof(managerWords));
    uint8_t f38 = vmRaw[0x38], f39 = vmRaw[0x39], f3a = vmRaw[0x3a];
    uintptr_t raw40 = 0, raw48 = 0, raw50 = 0, raw58 = 0;
    memcpy(&raw40, vmRaw + 0x40, sizeof(raw40));
    memcpy(&raw48, vmRaw + 0x48, sizeof(raw48));
    memcpy(&raw50, vmRaw + 0x50, sizeof(raw50));
    memcpy(&raw58, vmRaw + 0x58, sizeof(raw58));

    EB147Log(@"HOME_STATE147 phase=%@ vmFlags b38=%u b39=%u b3a=%u raw40=0x%llx raw48=0x%llx raw50=0x%llx raw58=0x%llx",
             phase, f38, f39, f3a,
             (unsigned long long)raw40, (unsigned long long)raw48,
             (unsigned long long)raw50, (unsigned long long)raw58);
    EB147Log(@"HOME_STATE147 phase=%@ managerExist w0=0x%llx w1=0x%llx w2=0x%llx meta=0x%llx witness=0x%llx managerClass=%p metaMatch=%d",
             phase,
             (unsigned long long)managerWords[0], (unsigned long long)managerWords[1],
             (unsigned long long)managerWords[2], (unsigned long long)managerWords[3],
             (unsigned long long)managerWords[4], managerClass,
             (managerClass && managerWords[3] == (uintptr_t)managerClass));

    if (managerClass && managerWords[3] == (uintptr_t)managerClass && managerWords[0]) {
        uint8_t mgrRaw[0x100] = {0};
        if (EB147Read(managerWords[0], mgrRaw, sizeof(mgrRaw))) {
            EB147Log(@"HOME_STATE147 phase=%@ manager_read_ok ptr=0x%llx b10=%u b18=%u b20=%u b28=%u b30=%u b38=%u b40=%u b48=%u b50=%u b58=%u",
                     phase, (unsigned long long)managerWords[0],
                     mgrRaw[0x10], mgrRaw[0x18], mgrRaw[0x20], mgrRaw[0x28], mgrRaw[0x30],
                     mgrRaw[0x38], mgrRaw[0x40], mgrRaw[0x48], mgrRaw[0x50], mgrRaw[0x58]);
        } else {
            EB147Log(@"HOME_STATE147 phase=%@ manager_read_failed ptr=0x%llx", phase, (unsigned long long)managerWords[0]);
        }
    }
}

%ctor {
    if (![[[NSBundle mainBundle] bundleIdentifier] isEqualToString:@"com.ebay.iphone"]) return;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        EB147Probe(@"2.5s", YES);
    });
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(5.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        EB147Probe(@"5s", NO);
    });
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(8.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        EB147Probe(@"8s", NO);
    });
}
