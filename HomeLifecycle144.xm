#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <mach-o/dyld.h>
#import <mach/mach.h>
#import <mach/mach_vm.h>

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
    } @catch (__unused NSException *exception) {}
}

#if defined(__arm64__)
extern void EB144CallSwiftX20(void *object, void *function);
__asm__(
".text\n"
".align 2\n"
"_EB144CallSwiftX20:\n"
"stp x20, x30, [sp, #-16]!\n"
"mov x20, x0\n"
"blr x1\n"
"ldp x20, x30, [sp], #16\n"
"ret\n"
);
#else
static void EB144CallSwiftX20(void *object, void *function) { (void)object; (void)function; }
#endif

static uintptr_t EB144HomeImageBase(void) {
    uint32_t count = _dyld_image_count();
    for (uint32_t i = 0; i < count; i++) {
        const char *name = _dyld_get_image_name(i);
        if (!name) continue;
        NSString *path = [NSString stringWithUTF8String:name];
        if ([path hasSuffix:@"/HomePageModule.framework/HomePageModule"]) {
            return (uintptr_t)_dyld_get_image_header(i);
        }
    }
    return 0;
}

static BOOL EB144ReadablePointer(uintptr_t address) {
    if (address < 0x100000000ULL) return NO;
    uintptr_t scratch = 0;
    mach_vm_size_t readSize = 0;
    kern_return_t kr = mach_vm_read_overwrite(mach_task_self(),
                                               (mach_vm_address_t)address,
                                               (mach_vm_size_t)sizeof(scratch),
                                               (mach_vm_address_t)&scratch,
                                               &readSize);
    return kr == KERN_SUCCESS && readSize == sizeof(scratch);
}

static Class EB144ClassNamed(NSArray<NSString *> *names) {
    for (NSString *name in names) {
        Class cls = NSClassFromString(name);
        if (cls) return cls;
    }
    return Nil;
}

static id EB144FindDirectObject(id owner, Class wanted, NSUInteger *foundOffset) {
    if (!owner || !wanted) return nil;
    size_t size = class_getInstanceSize([owner class]);
    uintptr_t base = (uintptr_t)(__bridge void *)owner;

    for (NSUInteger off = 0; off + sizeof(uintptr_t) <= size; off += sizeof(uintptr_t)) {
        uintptr_t candidate = 0;
        memcpy(&candidate, (void *)(base + off), sizeof(candidate));
        if (!EB144ReadablePointer(candidate)) continue;

        Class candidateClass = object_getClass((__bridge id)(void *)candidate);
        if (candidateClass == wanted) {
            if (foundOffset) *foundOffset = off;
            return (__bridge id)(void *)candidate;
        }
    }
    return nil;
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

static id EB144FindViewModel(UIViewController *controller, NSString **locationOut) {
    Class viewModelClass = EB144ClassNamed(@[
        @"_TtC14HomePageModule28VerticalLandingPageViewModel",
        @"HomePageModule.VerticalLandingPageViewModel"
    ]);
    if (!viewModelClass) {
        EB144Log(@"HOME_LIFE144 viewmodel_class_missing");
        return nil;
    }

    NSUInteger offset = 0;
    id vm = EB144FindDirectObject(controller, viewModelClass, &offset);
    if (vm) {
        if (locationOut) *locationOut = [NSString stringWithFormat:@"controller+0x%lx", (unsigned long)offset];
        return vm;
    }

    Class flowClass = EB144ClassNamed(@[
        @"_TtC14HomePageModule37HomeVerticalLandingPageFlowController",
        @"HomePageModule.HomeVerticalLandingPageFlowController"
    ]);
    if (flowClass) {
        NSUInteger flowOffset = 0;
        id flow = EB144FindDirectObject(controller, flowClass, &flowOffset);
        if (flow) {
            NSUInteger vmOffset = 0;
            vm = EB144FindDirectObject(flow, viewModelClass, &vmOffset);
            if (vm) {
                if (locationOut) *locationOut = [NSString stringWithFormat:@"flow(controller+0x%lx)+0x%lx", (unsigned long)flowOffset, (unsigned long)vmOffset];
                return vm;
            }
            EB144Log(@"HOME_LIFE144 flow_found offset=0x%lx size=%zu but_viewmodel_missing",
                     (unsigned long)flowOffset, class_getInstanceSize([flow class]));
        }
    }

    for (UIViewController *child in controller.childViewControllers) {
        NSUInteger childOffset = 0;
        vm = EB144FindDirectObject(child, viewModelClass, &childOffset);
        if (vm) {
            if (locationOut) *locationOut = [NSString stringWithFormat:@"child(%@)+0x%lx", NSStringFromClass([child class]), (unsigned long)childOffset];
            return vm;
        }
    }
    return nil;
}

static void EB144LogViewModelState(id vm, NSString *phase) {
    if (!vm) return;
    uintptr_t base = (uintptr_t)(__bridge void *)vm;
    uint8_t flags[3] = {0,0,0};
    memcpy(flags, (void *)(base + 0x38), sizeof(flags));

    id isLoading = nil;
    id sections = nil;
    id pageError = nil;
    @try { isLoading = [vm valueForKey:@"isLoading"]; } @catch (__unused NSException *e) {}
    @try { sections = [vm valueForKey:@"sections"]; } @catch (__unused NSException *e) {}
    @try { pageError = [vm valueForKey:@"pageError"]; } @catch (__unused NSException *e) {}

    NSUInteger sectionCount = [sections respondsToSelector:@selector(count)] ? [sections count] : 0;
    EB144Log(@"HOME_LIFE144 state=%@ vm=%p class=%@ raw38=%u raw39=%u raw3a=%u isLoading=%@ sections=%@ count=%lu pageError=%@",
             phase,
             (__bridge void *)vm,
             NSStringFromClass([vm class]),
             flags[0], flags[1], flags[2],
             isLoading ?: @"nil",
             sections ? NSStringFromClass([sections class]) : @"nil",
             (unsigned long)sectionCount,
             pageError ?: @"nil");
}

static BOOL EB144RepairOnce(void) {
    static BOOL repaired = NO;
    if (repaired) return YES;

    UIViewController *controller = EB144FindVLP();
    if (!controller) {
        EB144Log(@"HOME_LIFE144 controller_not_found");
        return NO;
    }

    NSString *location = nil;
    id vm = EB144FindViewModel(controller, &location);
    if (!vm) {
        EB144Log(@"HOME_LIFE144 viewmodel_not_found controller=%@ size=%zu",
                 NSStringFromClass([controller class]), class_getInstanceSize([controller class]));
        return NO;
    }

    uintptr_t imageBase = EB144HomeImageBase();
    if (!imageBase) {
        EB144Log(@"HOME_LIFE144 image_not_found");
        return NO;
    }

    void *setup = (void *)(imageBase + 0xF462C);
    void *fetch = (void *)(imageBase + 0xF46C4);
    EB144Log(@"HOME_LIFE144 viewmodel_found location=%@ vm=%p setup=%p fetch=%p",
             location ?: @"unknown", (__bridge void *)vm, setup, fetch);
    EB144LogViewModelState(vm, @"before_rebind");

    EB144CallSwiftX20((__bridge void *)vm, setup);
    EB144LogViewModelState(vm, @"after_rebind");

    EB144CallSwiftX20((__bridge void *)vm, fetch);
    EB144LogViewModelState(vm, @"after_refetch");

    repaired = YES;

    for (NSNumber *delay in @[@0.5, @1.5, @3.0, @6.0]) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay.doubleValue * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            EB144LogViewModelState(vm, [NSString stringWithFormat:@"post_%.1fs", delay.doubleValue]);
            id sectionModels = nil;
            @try { sectionModels = [controller valueForKey:@"sectionModels"]; } @catch (__unused NSException *e) {}
            NSUInteger count = [sectionModels respondsToSelector:@selector(count)] ? [sectionModels count] : 0;
            EB144Log(@"HOME_LIFE144 controller_sections post=%.1fs value=%@ count=%lu",
                     delay.doubleValue,
                     sectionModels ? NSStringFromClass([sectionModels class]) : @"nil",
                     (unsigned long)count);
        });
    }
    return YES;
}

%ctor {
    if (![[[NSBundle mainBundle] bundleIdentifier] isEqualToString:@"com.ebay.iphone"]) return;

    for (NSNumber *delay in @[@1.5, @2.5, @4.0, @6.0]) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay.doubleValue * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            if (!EB144RepairOnce()) EB144Log(@"HOME_LIFE144 retry delay=%.1fs", delay.doubleValue);
        });
    }
}
