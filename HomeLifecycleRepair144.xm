#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <mach-o/dyld.h>
#import <mach/mach.h>
#import <mach/mach_vm.h>

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
        if ([path hasSuffix:@"/HomePageModule.framework/HomePageModule"]) {
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

static Class EB144FindClass(NSArray<NSString *> *names) {
    for (NSString *name in names) {
        Class cls = NSClassFromString(name);
        if (cls) return cls;
    }
    return Nil;
}

static BOOL EB144Readable(uintptr_t address) {
    if (address < 0x100000000ULL) return NO;
    uintptr_t scratch = 0;
    mach_vm_size_t size = 0;
    kern_return_t kr = mach_vm_read_overwrite(mach_task_self(),
                                               (mach_vm_address_t)address,
                                               (mach_vm_size_t)sizeof(scratch),
                                               (mach_vm_address_t)&scratch,
                                               &size);
    return kr == KERN_SUCCESS && size == sizeof(scratch);
}

static id EB144FindObject(id owner, Class wanted, NSUInteger *offsetOut) {
    if (!owner || !wanted) return nil;
    size_t size = class_getInstanceSize([owner class]);
    uintptr_t base = (uintptr_t)(__bridge void *)owner;

    for (NSUInteger off = 0; off + sizeof(uintptr_t) <= size; off += sizeof(uintptr_t)) {
        uintptr_t candidate = 0;
        memcpy(&candidate, (void *)(base + off), sizeof(candidate));
        if (!EB144Readable(candidate)) continue;

        Class candidateClass = object_getClass((__bridge id)(void *)candidate);
        if (candidateClass == wanted) {
            if (offsetOut) *offsetOut = off;
            return (__bridge id)(void *)candidate;
        }
    }
    return nil;
}

static id EB144FindViewModel(UIViewController *vc, NSString **whereOut) {
    Class vmClass = EB144FindClass(@[
        @"_TtC14HomePageModule28VerticalLandingPageViewModel",
        @"HomePageModule.VerticalLandingPageViewModel"
    ]);
    if (!vmClass) {
        EB144Log(@"HOME_LIFE144 viewmodel_class_missing");
        return nil;
    }

    NSUInteger off = 0;
    id vm = EB144FindObject(vc, vmClass, &off);
    if (vm) {
        if (whereOut) *whereOut = [NSString stringWithFormat:@"controller+0x%lx", (unsigned long)off];
        return vm;
    }

    Class flowClass = EB144FindClass(@[
        @"_TtC14HomePageModule37HomeVerticalLandingPageFlowController",
        @"HomePageModule.HomeVerticalLandingPageFlowController"
    ]);
    if (flowClass) {
        NSUInteger flowOff = 0;
        id flow = EB144FindObject(vc, flowClass, &flowOff);
        if (flow) {
            NSUInteger vmOff = 0;
            vm = EB144FindObject(flow, vmClass, &vmOff);
            if (vm) {
                if (whereOut) *whereOut = [NSString stringWithFormat:@"flow(controller+0x%lx)+0x%lx", (unsigned long)flowOff, (unsigned long)vmOff];
                return vm;
            }
            EB144Log(@"HOME_LIFE144 flow_found offset=0x%lx size=%zu viewmodel_missing",
                     (unsigned long)flowOff, class_getInstanceSize([flow class]));
        }
    }

    for (UIViewController *child in vc.childViewControllers) {
        NSUInteger childOff = 0;
        vm = EB144FindObject(child, vmClass, &childOff);
        if (vm) {
            if (whereOut) *whereOut = [NSString stringWithFormat:@"child(%@)+0x%lx", NSStringFromClass([child class]), (unsigned long)childOff];
            return vm;
        }
    }
    return nil;
}

static id EB144FindManager(id vm, NSString **whereOut) {
    Class managerClass = EB144FindClass(@[
        @"_TtC14HomePageModule31VerticalLandingPageModelManager",
        @"HomePageModule.VerticalLandingPageModelManager"
    ]);
    if (!managerClass || !vm) return nil;

    NSUInteger off = 0;
    id manager = EB144FindObject(vm, managerClass, &off);
    if (manager && whereOut) *whereOut = [NSString stringWithFormat:@"viewmodel+0x%lx", (unsigned long)off];
    return manager;
}

static void EB144ProbeState(NSString *phase, UIViewController *vc, id vm, id manager) {
    id controllerSections = nil;
    @try { controllerSections = [vc valueForKey:@"sectionModels"]; } @catch (__unused NSException *e) {}
    NSUInteger controllerCount = [controllerSections respondsToSelector:@selector(count)] ? [controllerSections count] : 0;

    id vmSections = nil;
    id loading = nil;
    id pageError = nil;
    @try { vmSections = [vm valueForKey:@"sections"]; } @catch (__unused NSException *e) {}
    @try { loading = [vm valueForKey:@"isLoading"]; } @catch (__unused NSException *e) {}
    @try { pageError = [vm valueForKey:@"pageError"]; } @catch (__unused NSException *e) {}
    NSUInteger vmCount = [vmSections respondsToSelector:@selector(count)] ? [vmSections count] : 0;

    uint8_t flags[3] = {0, 0, 0};
    if (vm) memcpy(flags, (uint8_t *)(__bridge void *)vm + 0x38, sizeof(flags));

    EB144Log(@"HOME_LIFE144 phase=%@ controllerSections=%@ controllerCount=%lu vm=%@ raw38=%u raw39=%u raw3a=%u isLoading=%@ vmSections=%@ vmCount=%lu pageError=%@ manager=%@",
             phase,
             controllerSections ? NSStringFromClass([controllerSections class]) : @"nil",
             (unsigned long)controllerCount,
             vm ? NSStringFromClass([vm class]) : @"nil",
             flags[0], flags[1], flags[2],
             loading ?: @"nil",
             vmSections ? NSStringFromClass([vmSections class]) : @"nil",
             (unsigned long)vmCount,
             pageError ?: @"nil",
             manager ? NSStringFromClass([manager class]) : @"nil");
}

static BOOL EB144RepairNow(void) {
    if (EB144DidRepair) return YES;

    UIViewController *vc = EB144FindVLP();
    if (!vc) return NO;

    uintptr_t base = EB144HomeBase();
    if (!base) return NO;

    NSString *vmWhere = nil;
    id vm = EB144FindViewModel(vc, &vmWhere);
    if (!vm) {
        EB144Log(@"HOME_LIFE144 viewmodel_not_found controller=%@ size=%zu",
                 NSStringFromClass([vc class]), class_getInstanceSize([vc class]));
        return NO;
    }

    NSString *managerWhere = nil;
    id manager = EB144FindManager(vm, &managerWhere);
    EB144Log(@"HOME_LIFE144 viewmodel_found where=%@ ptr=%p managerWhere=%@ manager=%p",
             vmWhere ?: @"unknown", (__bridge void *)vm,
             managerWhere ?: @"not_found", manager ? (__bridge void *)manager : NULL);

    EB144ProbeState(@"before_rebind", vc, vm, manager);

    // Internal 6.96 VerticalLandingPageViewModel routines recovered from
    // HomePageModule. Both receive Swift self in x20.
    EB144Log(@"HOME_LIFE144 invoke setup=0xf462c");
    EB144CallX20Asm((void *)(base + 0xF462C), (__bridge void *)vm);
    EB144ProbeState(@"after_setup", vc, vm, manager);

    EB144Log(@"HOME_LIFE144 invoke fetch=0xf46c4");
    EB144CallX20Asm((void *)(base + 0xF46C4), (__bridge void *)vm);
    EB144ProbeState(@"after_fetch", vc, vm, manager);

    EB144DidRepair = YES;

    for (NSNumber *delay in @[@0.5, @1.5, @3.0, @6.0]) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay.doubleValue * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            EB144ProbeState([NSString stringWithFormat:@"post_%.1fs", delay.doubleValue], vc, vm, manager);
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
