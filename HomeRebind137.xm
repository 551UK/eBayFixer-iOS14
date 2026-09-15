#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <mach-o/dyld.h>
#import <mach/mach.h>
#import <mach/mach_vm.h>

extern void EB137CallSwiftSelf0(void *swiftSelf, void *function);

static BOOL EB138DidRebind = NO;

static NSString *EB138LogPath(void) {
    NSArray *paths = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
    NSString *dir = paths.firstObject ?: NSTemporaryDirectory();
    return [dir stringByAppendingPathComponent:@"eBayFixer.log"];
}

static void EB138Log(NSString *format, ...) {
    if (!format) return;
    va_list args;
    va_start(args, format);
    NSString *message = [[NSString alloc] initWithFormat:format arguments:args];
    va_end(args);
    if (!message.length) return;

    NSString *path = EB138LogPath();
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

static UIViewController *EB138FindVLPInController(UIViewController *vc) {
    if (!vc) return nil;
    NSString *name = NSStringFromClass([vc class]) ?: @"";
    if ([name containsString:@"HomeVerticalLandingPageViewController"]) return vc;

    if (vc.presentedViewController) {
        UIViewController *found = EB138FindVLPInController(vc.presentedViewController);
        if (found) return found;
    }
    if ([vc isKindOfClass:[UINavigationController class]]) {
        UIViewController *found = EB138FindVLPInController([(UINavigationController *)vc visibleViewController]);
        if (found) return found;
    }
    if ([vc isKindOfClass:[UITabBarController class]]) {
        UIViewController *found = EB138FindVLPInController([(UITabBarController *)vc selectedViewController]);
        if (found) return found;
    }
    for (UIViewController *child in vc.childViewControllers) {
        UIViewController *found = EB138FindVLPInController(child);
        if (found) return found;
    }
    return nil;
}

static UIViewController *EB138FindVLP(void) {
    for (UIWindow *window in [UIApplication sharedApplication].windows) {
        UIViewController *found = EB138FindVLPInController(window.rootViewController);
        if (found) return found;
    }
    return nil;
}

static void *EB138HomeImageBase(void) {
    uint32_t count = _dyld_image_count();
    for (uint32_t i = 0; i < count; i++) {
        const char *name = _dyld_get_image_name(i);
        if (!name || !strstr(name, "HomePageModule.framework/HomePageModule")) continue;
        const struct mach_header *header = _dyld_get_image_header(i);
        if (header) return (void *)header;
    }
    return NULL;
}

static BOOL EB138ReadWord(uintptr_t address, uintptr_t *value) {
    if (!address || !value) return NO;
    mach_vm_size_t outSize = 0;
    uintptr_t tmp = 0;
    kern_return_t kr = mach_vm_read_overwrite(mach_task_self(),
                                              (mach_vm_address_t)address,
                                              (mach_vm_size_t)sizeof(tmp),
                                              (mach_vm_address_t)&tmp,
                                              &outSize);
    if (kr != KERN_SUCCESS || outSize != sizeof(tmp)) return NO;
    *value = tmp;
    return YES;
}

static BOOL EB138MetadataMatches(uintptr_t objectHeader, uintptr_t metadata) {
    if (objectHeader == metadata) return YES;
    const uintptr_t mask = 0x0000FFFFFFFFFFF8ULL;
    return (objectHeader & mask) == (metadata & mask);
}

typedef void *(*EB138MetadataAccessor)(uintptr_t request);
typedef void *(*EB138OpenExistential)(void *storage, void *metadata);

typedef struct {
    UIViewController *controller;
    void *viewModel;
    void *modelManager;
    void *viewModelMetadata;
    size_t controllerOffset;
    uint8_t needsRefresh;
    uint8_t isRefreshing;
    uint8_t useCase;
    uint8_t isRetrieving;
} EB138State;

static void *EB138ViewModelMetadata(void *base) {
    if (!base) return NULL;
    // 6.96 HomePageModule metadata accessor for
    // HomePageModule.VerticalLandingPageViewModel.
    EB138MetadataAccessor accessor = (EB138MetadataAccessor)((uint8_t *)base + 0xF4820);
    return accessor(0);
}

static void *EB138FindViewModel(UIViewController *vc, void *metadata, void *imageBase, size_t *foundOffset) {
    if (!vc || !metadata) return NULL;

    uint8_t *objectBytes = (uint8_t *)(__bridge void *)vc;
    size_t instanceSize = class_getInstanceSize([vc class]);
    uintptr_t wanted = (uintptr_t)metadata;
    uintptr_t imageStart = (uintptr_t)imageBase;
    uintptr_t imageEnd = imageStart ? imageStart + 0x210000 : 0;
    NSMutableArray<NSString *> *nearbySwift = [NSMutableArray array];

    for (size_t offset = 0; offset + sizeof(uintptr_t) <= instanceSize; offset += sizeof(uintptr_t)) {
        uintptr_t candidate = 0;
        memcpy(&candidate, objectBytes + offset, sizeof(candidate));
        if (candidate < 0x100000000ULL || candidate > 0x0000FFFFFFFFFFFFULL || (candidate & 0x7)) continue;

        uintptr_t header = 0;
        if (!EB138ReadWord(candidate, &header)) continue;
        if (EB138MetadataMatches(header, wanted)) {
            if (foundOffset) *foundOffset = offset;
            EB138Log(@"HOME_STATE138 vm_found controllerOffset=0x%zx vm=%p header=%p metadata=%p instanceSize=0x%zx",
                     offset, (void *)candidate, (void *)header, metadata, instanceSize);
            return (void *)candidate;
        }

        if (imageStart && header >= imageStart && header < imageEnd && nearbySwift.count < 16) {
            [nearbySwift addObject:[NSString stringWithFormat:@"off=0x%zx obj=%p meta=%p",
                                    offset, (void *)candidate, (void *)header]];
        }
    }

    EB138Log(@"HOME_STATE138 vm_not_found wanted=%p instanceSize=0x%zx nearby=[%@]",
             metadata, instanceSize, [nearbySwift componentsJoinedByString:@" | "]);
    return NULL;
}

static BOOL EB138ReadState(EB138State *state, NSString *phase) {
    if (!state) return NO;
    memset(state, 0, sizeof(*state));

    UIViewController *vc = EB138FindVLP();
    if (!vc) {
        EB138Log(@"HOME_STATE138 phase=%@ controller=not_found", phase);
        return NO;
    }
    state->controller = vc;

    void *base = EB138HomeImageBase();
    if (!base) {
        EB138Log(@"HOME_STATE138 phase=%@ image_base_not_found", phase);
        return NO;
    }

    void *vmMetadata = EB138ViewModelMetadata(base);
    state->viewModelMetadata = vmMetadata;
    if (!vmMetadata) {
        EB138Log(@"HOME_STATE138 phase=%@ vm_metadata_nil", phase);
        return NO;
    }

    size_t controllerOffset = 0;
    void *viewModel = EB138FindViewModel(vc, vmMetadata, base, &controllerOffset);
    if (!viewModel) {
        EB138Log(@"HOME_STATE138 phase=%@ controller=%@ vm_unresolved metadata=%p",
                 phase, NSStringFromClass([vc class]), vmMetadata);
        return NO;
    }

    state->viewModel = viewModel;
    state->controllerOffset = controllerOffset;

    // These are direct fixed offsets proven by the 6.96 disassembly:
    // f462c zeroes 0x38/0x39, f46c4 checks 0x39 and passes 0x3a to manager.
    state->needsRefresh = *((uint8_t *)viewModel + 0x38);
    state->isRefreshing = *((uint8_t *)viewModel + 0x39);
    state->useCase = *((uint8_t *)viewModel + 0x3A);

    // The ViewModel stores ModelManager as a Swift existential at +0x10.
    // HomePageModule+0xBE08 is the exact helper used by f462c/f46c4 to open it.
    void *existentialMetadata = *(void **)((uint8_t *)viewModel + 0x28);
    EB138OpenExistential openExistential = (EB138OpenExistential)((uint8_t *)base + 0xBE08);
    void *opened = existentialMetadata ? openExistential((uint8_t *)viewModel + 0x10, existentialMetadata) : NULL;
    void *manager = opened ? *(void **)opened : NULL;
    state->modelManager = manager;

    uintptr_t managerHeader = 0;
    BOOL managerReadable = manager && EB138ReadWord((uintptr_t)manager, &managerHeader);
    state->isRetrieving = managerReadable ? *((uint8_t *)manager + 0x20) : 0xFF;

    void *subject = managerReadable ? *(void **)((uint8_t *)manager + 0x10) : NULL;
    void *feedSubject = managerReadable ? *(void **)((uint8_t *)manager + 0x18) : NULL;
    void *requestMeta = managerReadable ? *(void **)((uint8_t *)manager + 0x48) : NULL;
    void *networkMeta = managerReadable ? *(void **)((uint8_t *)manager + 0x70) : NULL;
    void *transformMeta = managerReadable ? *(void **)((uint8_t *)manager + 0x98) : NULL;

    EB138Log(@"HOME_STATE138 phase=%@ controller=%@ vcOff=0x%zx vm=%p vmMeta=%p flags=[needs=%u refreshing=%u useCase=%u] existentialMeta=%p manager=%p managerHeader=%p readable=%d retrieving=%u subject=%p feed=%p reqMeta=%p netMeta=%p transformMeta=%p",
             phase, NSStringFromClass([vc class]), controllerOffset,
             viewModel, vmMetadata,
             state->needsRefresh, state->isRefreshing, state->useCase,
             existentialMetadata, manager, (void *)managerHeader, managerReadable,
             state->isRetrieving, subject, feedSubject, requestMeta, networkMeta, transformMeta);

    return YES;
}

static void EB138RebindAndRefetch(void) {
    if (EB138DidRebind) return;

    EB138State state;
    if (!EB138ReadState(&state, @"pre_rebind") || !state.viewModel) return;

    void *base = EB138HomeImageBase();
    if (!base) return;

    // 6.96 ViewModel internals:
    // 0xF462C subscribes the ViewModel to ModelManager's publisher.
    // 0xF46C4 starts fetch if the ViewModel is not already refreshing.
    void *setupFunction = (uint8_t *)base + 0xF462C;
    void *fetchFunction = (uint8_t *)base + 0xF46C4;

    EB138DidRebind = YES;
    EB138Log(@"HOME_REBIND138 begin base=%p vm=%p setup=%p fetch=%p before=[needs=%u refreshing=%u retrieving=%u useCase=%u]",
             base, state.viewModel, setupFunction, fetchFunction,
             state.needsRefresh, state.isRefreshing, state.isRetrieving, state.useCase);

    EB137CallSwiftSelf0(state.viewModel, setupFunction);
    EB138Log(@"HOME_REBIND138 setup_called=1");

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.20 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        EB137CallSwiftSelf0(state.viewModel, fetchFunction);
        EB138Log(@"HOME_REBIND138 fetch_called=1");
        EB138State after;
        EB138ReadState(&after, @"post_fetch");
    });
}

%ctor {
    @autoreleasepool {
        if (![[[NSBundle mainBundle] bundleIdentifier] isEqualToString:@"com.ebay.iphone"]) return;

        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.25 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            EB138RebindAndRefetch();
        });
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(4.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            EB138State state; EB138ReadState(&state, @"4s");
        });
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(8.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            EB138State state; EB138ReadState(&state, @"8s");
        });
    }
}
