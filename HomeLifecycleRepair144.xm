#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <mach-o/dyld.h>

extern "C" void *EB144ProjectExistentialAsm(void *fn, void *existential, void *metadata);
extern "C" void EB144CallX20Asm(void *fn, void *object);

static BOOL EB144DidRepair = NO;

static NSString *EB144LogPath(void) {
    NSArray *paths = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
    NSString *dir = paths.firstObject ?: NSTemporaryDirectory();
    return [dir stringByAppendingPathComponent:@"eBayFixer.log"];
}

static void EB144Log(NSString *format, ...) {
    if (!format) return;
    va_list args;
    va_start(args, format);
    NSString *message = [[NSString alloc] initWithFormat:format arguments:args];
    va_end(args);
    if (!message.length) return;

    NSString *path = EB144LogPath();
    if (![[NSFileManager defaultManager] fileExistsAtPath:path]) {
        [[NSFileManager defaultManager] createFileAtPath:path contents:nil attributes:nil];
    }
    NSFileHandle *handle = [NSFileHandle fileHandleForWritingAtPath:path];
    if (!handle) return;
    NSString *line = [NSString stringWithFormat:@"%@ %@\n", [NSDate date], message];
    @try {
        [handle seekToEndOfFile];
        [handle writeData:[line dataUsingEncoding:NSUTF8StringEncoding]];
        [handle closeFile];
    } @catch (__unused NSException *e) {}
}

static uintptr_t EB144HomeBase(void) {
    static uintptr_t cached = 0;
    if (cached) return cached;
    uint32_t count = _dyld_image_count();
    for (uint32_t i = 0; i < count; i++) {
        const char *name = _dyld_get_image_name(i);
        if (!name) continue;
        NSString *path = [NSString stringWithUTF8String:name];
        if ([path containsString:@"/HomePageModule.framework/HomePageModule"]) {
            cached = (uintptr_t)_dyld_get_image_header(i);
            EB144Log(@"HOME_LIFE144 image=%@ base=0x%llx", path, (unsigned long long)cached);
            break;
        }
    }
    return cached;
}

static UIViewController *EB144FindVLPIn(UIViewController *vc) {
    if (!vc) return nil;
    if ([NSStringFromClass([vc class]) containsString:@"HomeVerticalLandingPageViewController"]) return vc;
    if (vc.presentedViewController) {
        UIViewController *found = EB144FindVLPIn(vc.presentedViewController);
        if (found) return found;
    }
    if ([vc isKindOfClass:[UINavigationController class]]) {
        UIViewController *found = EB144FindVLPIn([(UINavigationController *)vc visibleViewController]);
        if (found) return found;
    }
    if ([vc isKindOfClass:[UITabBarController class]]) {
        UIViewController *found = EB144FindVLPIn([(UITabBarController *)vc selectedViewController]);
        if (found) return found;
    }
    for (UIViewController *child in vc.childViewControllers) {
        UIViewController *found = EB144FindVLPIn(child);
        if (found) return found;
    }
    return nil;
}

static UIViewController *EB144FindVLP(void) {
    for (UIWindow *window in [UIApplication sharedApplication].windows) {
        UIViewController *found = EB144FindVLPIn(window.rootViewController);
        if (found) return found;
    }
    return nil;
}

static uintptr_t EB144RuntimeOffset(uintptr_t base, uintptr_t slot, uintptr_t maxValue) {
    if (!base) return 0;
    uintptr_t value = *(uintptr_t *)(base + slot);
    if (!value || value > maxValue) return 0;
    return value;
}

static void *EB144Project(uintptr_t base, void *existential) {
    if (!base || !existential) return NULL;
    void *metadata = *(void **)((uint8_t *)existential + 0x18);
    if (!metadata) return NULL;
    void *storage = EB144ProjectExistentialAsm((void *)(base + 0xBE08), existential, metadata);
    if (!storage) return NULL;
    return *(void **)storage;
}

static NSString *EB144ObjectClass(void *ptr) {
    if (!ptr) return @"nil";
    id obj = (__bridge id)ptr;
    @try { return NSStringFromClass([obj class]) ?: @"unknown"; }
    @catch (__unused NSException *e) { return @"invalid"; }
}

static void EB144ProbeState(NSString *phase, UIViewController *vc, uintptr_t base, void *vm, void *manager) {
    id sections = nil;
    @try { sections = [vc valueForKey:@"sectionModels"]; } @catch (__unused NSException *e) {}
    NSUInteger sectionCount = [sections respondsToSelector:@selector(count)] ? [sections count] : 0;

    uintptr_t needsOff = EB144RuntimeOffset(base, 0x116720, 0x200);
    uintptr_t refreshingOff = EB144RuntimeOffset(base, 0x116728, 0x200);
    uintptr_t useCaseOff = EB144RuntimeOffset(base, 0x116730, 0x200);
    uintptr_t retrievingOff = EB144RuntimeOffset(base, 0x114BB0, 0x300);

    int needs = (vm && needsOff) ? *((uint8_t *)vm + needsOff) : -1;
    int refreshing = (vm && refreshingOff) ? *((uint8_t *)vm + refreshingOff) : -1;
    int useCase = (vm && useCaseOff) ? *((uint8_t *)vm + useCaseOff) : -1;
    int retrieving = (manager && retrievingOff) ? *((uint8_t *)manager + retrievingOff) : -1;

    EB144Log(@"HOME_LIFE144 phase=%@ sections=%@ count=%lu vm=%@ needs=%d refreshing=%d useCase=%d manager=%@ retrieving=%d",
             phase,
             sections ? NSStringFromClass([sections class]) : @"nil",
             (unsigned long)sectionCount,
             EB144ObjectClass(vm), needs, refreshing, useCase,
             EB144ObjectClass(manager), retrieving);
}

static BOOL EB144RepairNow(void) {
    if (EB144DidRepair) return YES;
    UIViewController *vc = EB144FindVLP();
    if (!vc) return NO;

    uintptr_t base = EB144HomeBase();
    if (!base) return NO;

    uintptr_t vmOffset = EB144RuntimeOffset(base, 0x194920, class_getInstanceSize([vc class]) + 0x100);
    if (!vmOffset) {
        EB144Log(@"HOME_LIFE144 vm_offset_invalid classSize=%zu", class_getInstanceSize([vc class]));
        return NO;
    }

    void *vmExistential = (uint8_t *)(__bridge void *)vc + vmOffset;
    void *vm = EB144Project(base, vmExistential);
    NSString *vmClass = EB144ObjectClass(vm);
    EB144Log(@"HOME_LIFE144 vm_offset=0x%llx vm=%p class=%@", (unsigned long long)vmOffset, vm, vmClass);
    if (!vm || ![vmClass containsString:@"VerticalLandingPageViewModel"]) return NO;

    uintptr_t managerOffset = EB144RuntimeOffset(base, 0x116718, 0x200);
    void *manager = NULL;
    if (managerOffset) {
        void *managerExistential = (uint8_t *)vm + managerOffset;
        manager = EB144Project(base, managerExistential);
    }
    EB144Log(@"HOME_LIFE144 manager_offset=0x%llx manager=%p class=%@",
             (unsigned long long)managerOffset, manager, EB144ObjectClass(manager));

    EB144ProbeState(@"before_rebind", vc, base, vm, manager);

    // These are the exact internal 6.96 ViewModel routines recovered from
    // HomePageModule: setup subscriptions at 0xF462C, then fetch at 0xF46C4.
    // Both use Swift's internal x20 self convention, hence the tiny asm bridge.
    EB144Log(@"HOME_LIFE144 invoke setup=0xf462c fetch=0xf46c4");
    EB144CallX20Asm((void *)(base + 0xF462C), vm);
    EB144ProbeState(@"after_setup", vc, base, vm, manager);
    EB144CallX20Asm((void *)(base + 0xF46C4), vm);
    EB144ProbeState(@"after_fetch", vc, base, vm, manager);

    EB144DidRepair = YES;

    for (NSNumber *delay in @[@1.0, @3.0, @6.0]) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay.doubleValue * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            EB144ProbeState([NSString stringWithFormat:@"post_%@s", delay], vc, base, vm, manager);
        });
    }
    return YES;
}

static void EB144Try(NSUInteger attempt) {
    if (EB144DidRepair) return;
    if (EB144RepairNow()) return;
    if (attempt >= 12) {
        EB144Log(@"HOME_LIFE144 repair_not_applied attempts=%lu", (unsigned long)attempt);
        return;
    }
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.75 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        EB144Try(attempt + 1);
    });
}

%ctor {
    if (![[[NSBundle mainBundle] bundleIdentifier] isEqualToString:@"com.ebay.iphone"]) return;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        EB144Try(1);
    });
}
