#import <Foundation/Foundation.h>
#import <mach-o/dyld.h>
#import <mach-o/loader.h>
#import <substrate.h>

static const uintptr_t EB126RouteBranchOffset = 0x38F08;

static NSString *EB126LogPath(void) {
    NSArray *paths = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
    NSString *dir = paths.firstObject ?: NSTemporaryDirectory();
    return [dir stringByAppendingPathComponent:@"eBayFixer.log"];
}

static void EB126Log(NSString *format, ...) {
    va_list args;
    va_start(args, format);
    NSString *message = [[NSString alloc] initWithFormat:format arguments:args];
    va_end(args);
    if (!message.length) return;

    NSString *line = [NSString stringWithFormat:@"%@ %@\n", [NSDate date], message];
    NSData *data = [line dataUsingEncoding:NSUTF8StringEncoding];
    NSString *path = EB126LogPath();
    if (![[NSFileManager defaultManager] fileExistsAtPath:path]) {
        [[NSFileManager defaultManager] createFileAtPath:path contents:nil attributes:nil];
    }
    NSFileHandle *handle = [NSFileHandle fileHandleForWritingAtPath:path];
    if (!handle) return;
    @try {
        [handle seekToEndOfFile];
        [handle writeData:data];
        [handle closeFile];
    } @catch (__unused NSException *exception) {}
}

static BOOL EB126IsHomePageModule(const struct mach_header *header) {
    if (!header) return NO;
    uint32_t count = _dyld_image_count();
    for (uint32_t i = 0; i < count; i++) {
        if (_dyld_get_image_header(i) != header) continue;
        const char *name = _dyld_get_image_name(i);
        if (!name) return NO;
        NSString *path = [NSString stringWithUTF8String:name];
        return [path hasSuffix:@"/HomePageModule.framework/HomePageModule"];
    }
    return NO;
}

static void EB126LogResultLater(NSString *message) {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        EB126Log(@"HOME_ROUTE_PATCH %@", message);
    });
}

static void EB126PatchImage(const struct mach_header *header, intptr_t slide) {
    (void)slide;
    if (!EB126IsHomePageModule(header)) return;

    uint8_t *target = (uint8_t *)header + EB126RouteBranchOffset;
    const uint8_t original[4] = {0x94, 0x00, 0x00, 0x36}; // tbz w20,#0,legacyPath
    const uint8_t forcedVLP[4] = {0x1F, 0x20, 0x03, 0xD5}; // nop => always fall through to VLP=true path

    if (memcmp(target, forcedVLP, sizeof(forcedVLP)) == 0) {
        EB126LogResultLater(@"already_applied offset=0x38f08");
        return;
    }

    if (memcmp(target, original, sizeof(original)) != 0) {
        EB126LogResultLater([NSString stringWithFormat:
            @"mismatch offset=0x38f08 bytes=%02x%02x%02x%02x",
            target[0], target[1], target[2], target[3]]);
        return;
    }

    MSHookMemory(target, forcedVLP, sizeof(forcedVLP));
    BOOL ok = memcmp(target, forcedVLP, sizeof(forcedVLP)) == 0;
    EB126LogResultLater(ok ? @"applied offset=0x38f08 forced_vlp_path=1" : @"write_failed offset=0x38f08");
}

static void EB126ImageAdded(const struct mach_header *header, intptr_t slide) {
    EB126PatchImage(header, slide);
}

%ctor {
    @autoreleasepool {
        if (![[[NSBundle mainBundle] bundleIdentifier] isEqualToString:@"com.ebay.iphone"]) return;

        _dyld_register_func_for_add_image(EB126ImageAdded);

        uint32_t count = _dyld_image_count();
        for (uint32_t i = 0; i < count; i++) {
            EB126PatchImage(_dyld_get_image_header(i), _dyld_get_image_vmaddr_slide(i));
        }
    }
}
