#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <dlfcn.h>
#import <substrate.h>

static const uintptr_t EB128InitialRouteOffset = 0x38BD8;
static const uintptr_t EB128StateRouteOffset = 0x38F08;
static BOOL EB128Finished = NO;
static BOOL EB128LoggedStart = NO;

static NSString *EB128LogPath(void) {
    NSArray *paths = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
    NSString *dir = paths.firstObject ?: NSTemporaryDirectory();
    return [dir stringByAppendingPathComponent:@"eBayFixer.log"];
}

static void EB128Log(NSString *format, ...) {
    va_list args;
    va_start(args, format);
    NSString *message = [[NSString alloc] initWithFormat:format arguments:args];
    va_end(args);
    if (!message.length) return;

    NSString *path = EB128LogPath();
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

static void EB128LogLater(NSString *message) {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.25 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        EB128Log(@"HOME_ROUTE128 %@", message);
    });
}

static void *EB128HomeImageBase(void) {
    Class cls = objc_getClass("_TtC14HomePageModule37HomeVerticalLandingPageViewController");
    if (!cls) return NULL;

    Method method = class_getInstanceMethod(cls, @selector(viewDidAppear:));
    if (!method) method = class_getInstanceMethod(cls, @selector(viewWillAppear:));
    if (!method) return NULL;

    IMP imp = method_getImplementation(method);
    if (!imp) return NULL;

    Dl_info info = {0};
    if (dladdr((const void *)imp, &info) == 0 || !info.dli_fbase) return NULL;
    if (info.dli_fname && !strstr(info.dli_fname, "HomePageModule")) {
        EB128LogLater([NSString stringWithFormat:@"locator_wrong_image path=%s", info.dli_fname]);
        return NULL;
    }
    return info.dli_fbase;
}

static BOOL EB128Patch4(uint8_t *base,
                        uintptr_t offset,
                        const uint8_t expected[4],
                        const uint8_t replacement[4],
                        NSString *label) {
    uint8_t *target = base + offset;

    if (memcmp(target, replacement, 4) == 0) {
        EB128LogLater([NSString stringWithFormat:@"%@ already_applied offset=0x%lx", label, (unsigned long)offset]);
        return YES;
    }

    if (memcmp(target, expected, 4) != 0) {
        EB128LogLater([NSString stringWithFormat:@"%@ mismatch offset=0x%lx bytes=%02x%02x%02x%02x",
                       label, (unsigned long)offset,
                       target[0], target[1], target[2], target[3]]);
        return NO;
    }

    MSHookMemory(target, replacement, 4);
    BOOL ok = memcmp(target, replacement, 4) == 0;
    EB128LogLater([NSString stringWithFormat:@"%@ %@ offset=0x%lx",
                   label, ok ? @"applied" : @"write_failed", (unsigned long)offset]);
    return ok;
}

static void EB128TryPatch(void) {
    if (EB128Finished) return;

    if (!EB128LoggedStart) {
        EB128LoggedStart = YES;
        EB128LogLater(@"start class_locator=VLP.viewDidAppear");
    }

    uint8_t *base = (uint8_t *)EB128HomeImageBase();
    if (!base) return;

    const uint8_t nop[4] = {0x1F, 0x20, 0x03, 0xD5};

    // HomeTabCoordinator constructor, before either Home controller is built:
    // 0x38BD8: tbz w20,#0,0x38C00
    // False branches directly into the legacy HomeContentViewController setup.
    // NOP forces fall-through into 0x38ED0, the VLP setup path.
    const uint8_t initialExpected[4] = {0x54, 0x01, 0x00, 0x36};

    // Secondary Home enabled-state transition inside the VLP path:
    // 0x38F08: tbz w20,#0,0x38F18
    const uint8_t stateExpected[4] = {0x94, 0x00, 0x00, 0x36};

    BOOL initial = EB128Patch4(base, EB128InitialRouteOffset, initialExpected, nop, @"initial_vlp_route");
    BOOL state = EB128Patch4(base, EB128StateRouteOffset, stateExpected, nop, @"vlp_state_route");

    EB128Finished = initial && state;
    if (EB128Finished) {
        EB128LogLater([NSString stringWithFormat:@"complete=1 base=%p forced_initial_vlp=1", base]);
    }
}

static void EB128ScheduleRetries(void) {
    NSArray<NSNumber *> *delays = @[@0.0, @0.005, @0.01, @0.02, @0.04, @0.08, @0.15, @0.30, @0.60];
    for (NSNumber *delay in delays) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay.doubleValue * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            EB128TryPatch();
        });
    }
}

%ctor {
    @autoreleasepool {
        if (![[[NSBundle mainBundle] bundleIdentifier] isEqualToString:@"com.ebay.iphone"]) return;
        EB128TryPatch();
        EB128ScheduleRetries();
    }
}
