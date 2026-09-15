#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <dlfcn.h>
#import <substrate.h>

static const uintptr_t EB127RouteBranchOffset = 0x38F08;
static BOOL EB127Finished = NO;
static BOOL EB127LoggedStart = NO;

static NSString *EB127LogPath(void) {
    NSArray *paths = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
    NSString *dir = paths.firstObject ?: NSTemporaryDirectory();
    return [dir stringByAppendingPathComponent:@"eBayFixer.log"];
}

static void EB127Log(NSString *format, ...) {
    va_list args;
    va_start(args, format);
    NSString *message = [[NSString alloc] initWithFormat:format arguments:args];
    va_end(args);
    if (!message.length) return;

    NSString *path = EB127LogPath();
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

static void EB127LogLater(NSString *message) {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.25 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        EB127Log(@"HOME_ROUTE127 %@", message);
    });
}

static void *EB127HomeImageBase(void) {
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
        EB127LogLater([NSString stringWithFormat:@"locator_wrong_image path=%s", info.dli_fname]);
        return NULL;
    }

    return info.dli_fbase;
}

static void EB127TryPatch(void) {
    if (EB127Finished) return;

    if (!EB127LoggedStart) {
        EB127LoggedStart = YES;
        EB127LogLater(@"start class_locator=VLP.viewDidAppear");
    }

    uint8_t *base = (uint8_t *)EB127HomeImageBase();
    if (!base) return;

    uint8_t *target = base + EB127RouteBranchOffset;
    const uint8_t original[4] = {0x94, 0x00, 0x00, 0x36}; // tbz w20,#0,legacy path
    const uint8_t forcedVLP[4] = {0x1F, 0x20, 0x03, 0xD5}; // nop: always use VLP=true path

    if (memcmp(target, forcedVLP, 4) == 0) {
        EB127Finished = YES;
        EB127LogLater([NSString stringWithFormat:@"already_applied base=%p offset=0x38f08", base]);
        return;
    }

    if (memcmp(target, original, 4) != 0) {
        EB127LogLater([NSString stringWithFormat:@"mismatch base=%p offset=0x38f08 bytes=%02x%02x%02x%02x",
                       base, target[0], target[1], target[2], target[3]]);
        return;
    }

    MSHookMemory(target, forcedVLP, 4);
    if (memcmp(target, forcedVLP, 4) == 0) {
        EB127Finished = YES;
        EB127LogLater([NSString stringWithFormat:@"applied base=%p offset=0x38f08 forced_vlp_path=1", base]);
    } else {
        EB127LogLater([NSString stringWithFormat:@"write_failed base=%p offset=0x38f08", base]);
    }
}

static void EB127ScheduleRetries(void) {
    // HomePageModule is linked at launch in the supplied app, but retry briefly in case
    // Swift/ObjC class registration completes after our tweak constructor.
    NSArray<NSNumber *> *delays = @[@0.0, @0.01, @0.03, @0.08, @0.15, @0.30, @0.60];
    for (NSNumber *delay in delays) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay.doubleValue * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            EB127TryPatch();
        });
    }
}

%ctor {
    @autoreleasepool {
        if (![[[NSBundle mainBundle] bundleIdentifier] isEqualToString:@"com.ebay.iphone"]) return;

        // Try synchronously first so the coordinator branch is patched before Home routing.
        EB127TryPatch();
        EB127ScheduleRetries();
    }
}
