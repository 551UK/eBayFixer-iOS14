#import <Foundation/Foundation.h>
#import <mach-o/dyld.h>
#import <mach-o/loader.h>
#import <substrate.h>

static NSString *EB124LogPath(void) {
    NSArray *paths = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
    NSString *dir = paths.firstObject ?: NSTemporaryDirectory();
    return [dir stringByAppendingPathComponent:@"eBayFixer.log"];
}

static void EB124Log(NSString *format, ...) {
    if (!format) return;
    va_list args;
    va_start(args, format);
    NSString *message = [[NSString alloc] initWithFormat:format arguments:args];
    va_end(args);
    if (!message.length) return;

    NSString *path = EB124LogPath();
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

static BOOL EB124IsHomePageModule(const struct mach_header *header) {
    if (!header) return NO;
    const uint8_t *cursor = (const uint8_t *)header;
    const struct mach_header_64 *mh = (const struct mach_header_64 *)header;
    if (mh->magic != MH_MAGIC_64) return NO;

    cursor += sizeof(struct mach_header_64);
    for (uint32_t i = 0; i < mh->ncmds; i++) {
        const struct load_command *lc = (const struct load_command *)cursor;
        if (lc->cmd == LC_ID_DYLIB && lc->cmdsize >= sizeof(struct dylib_command)) {
            const struct dylib_command *dc = (const struct dylib_command *)lc;
            if (dc->dylib.name.offset < lc->cmdsize) {
                const char *name = (const char *)cursor + dc->dylib.name.offset;
                if (name && strstr(name, "HomePageModule.framework/HomePageModule")) return YES;
            }
        }
        if (lc->cmdsize < sizeof(struct load_command)) break;
        cursor += lc->cmdsize;
    }
    return NO;
}

static BOOL EB124Patch4(uint8_t *base,
                        uintptr_t offset,
                        const uint8_t expected[4],
                        const uint8_t replacement[4],
                        NSString *label) {
    if (!base) return NO;
    uint8_t *target = base + offset;

    if (memcmp(target, replacement, 4) == 0) {
        EB124Log(@"HOME_BIN_PATCH %@ already patched offset=0x%lx", label, (unsigned long)offset);
        return YES;
    }

    if (memcmp(target, expected, 4) != 0) {
        EB124Log(@"HOME_BIN_PATCH %@ mismatch offset=0x%lx bytes=%02x %02x %02x %02x",
                 label, (unsigned long)offset,
                 target[0], target[1], target[2], target[3]);
        return NO;
    }

    MSHookMemory(target, replacement, 4);
    BOOL ok = (memcmp(target, replacement, 4) == 0);
    EB124Log(@"HOME_BIN_PATCH %@ %@ offset=0x%lx",
             label, ok ? @"applied" : @"FAILED", (unsigned long)offset);
    return ok;
}

static void EB124PatchHomePageModule(const struct mach_header *header) {
    static BOOL finished = NO;
    if (finished || !EB124IsHomePageModule(header)) return;

    uint8_t *base = (uint8_t *)header;

    // eBay iOS 14 build supplied for this project (actual app generation 6.96):
    // 0xE4B80: strb wzr, [sp,#0x38]  -> default homescreen.vlpF90 = false
    // 0xE4BC8: strb w26, [sp,#0x30]  -> default homescreen.vlpF90KillSwitch = true
    // Force the inverse before HomePageFeatureToggles is materialized.
    const uint8_t f90Expected[4] = {0xFF, 0xE3, 0x00, 0x39};
    const uint8_t f90Enabled[4]  = {0xFA, 0xE3, 0x00, 0x39};
    const uint8_t killExpected[4] = {0xFA, 0xC3, 0x00, 0x39};
    const uint8_t killDisabled[4] = {0xFF, 0xC3, 0x00, 0x39};

    BOOL f90 = EB124Patch4(base, 0xE4B80, f90Expected, f90Enabled, @"vlpF90=1");
    BOOL kill = EB124Patch4(base, 0xE4BC8, killExpected, killDisabled, @"vlpF90KillSwitch=0");
    finished = f90 && kill;

    EB124Log(@"HOME_BIN_PATCH complete=%d image=%p", finished, header);
}

static void EB124ImageAdded(const struct mach_header *mh, intptr_t vmaddr_slide) {
    (void)vmaddr_slide;
    EB124PatchHomePageModule(mh);
}

%ctor {
    @autoreleasepool {
        if (![[[NSBundle mainBundle] bundleIdentifier] isEqualToString:@"com.ebay.iphone"]) return;

        // Register first so a late-loaded HomePageModule is patched as soon as dyld adds it.
        _dyld_register_func_for_add_image(EB124ImageAdded);

        // Also scan images already present when the tweak constructor runs.
        uint32_t count = _dyld_image_count();
        for (uint32_t i = 0; i < count; i++) {
            EB124PatchHomePageModule(_dyld_get_image_header(i));
        }
    }
}
