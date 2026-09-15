#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <mach-o/dyld.h>

extern void EB137CallSwiftSelf0(void *swiftSelf, void *function);

static BOOL EB137DidRebind = NO;

static NSString *EB137LogPath(void) {
    NSArray *paths = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
    NSString *dir = paths.firstObject ?: NSTemporaryDirectory();
    return [dir stringByAppendingPathComponent:@"eBayFixer.log"];
}

static void EB137Log(NSString *format, ...) {
    if (!format) return;
    va_list args;
    va_start(args, format);
    NSString *message = [[NSString alloc] initWithFormat:format arguments:args];
    va_end(args);
    if (!message.length) return;

    NSString *path = EB137LogPath();
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

static UIViewController *EB137FindVLPInController(UIViewController *vc) {
    if (!vc) return nil;
    NSString *name = NSStringFromClass([vc class]) ?: @"";
    if ([name containsString:@"HomeVerticalLandingPageViewController"]) return vc;

    if (vc.presentedViewController) {
        UIViewController *found = EB137FindVLPInController(vc.presentedViewController);
        if (found) return found;
    }
    if ([vc isKindOfClass:[UINavigationController class]]) {
        UIViewController *found = EB137FindVLPInController([(UINavigationController *)vc visibleViewController]);
        if (found) return found;
    }
    if ([vc isKindOfClass:[UITabBarController class]]) {
        UIViewController *found = EB137FindVLPInController([(UITabBarController *)vc selectedViewController]);
        if (found) return found;
    }
    for (UIViewController *child in vc.childViewControllers) {
        UIViewController *found = EB137FindVLPInController(child);
        if (found) return found;
    }
    return nil;
}

static UIViewController *EB137FindVLP(void) {
    for (UIWindow *window in [UIApplication sharedApplication].windows) {
        UIViewController *found = EB137FindVLPInController(window.rootViewController);
        if (found) return found;
    }
    return nil;
}

static void *EB137HomeImageBase(void) {
    uint32_t count = _dyld_image_count();
    for (uint32_t i = 0; i < count; i++) {
        const char *name = _dyld_get_image_name(i);
        if (!name || !strstr(name, "HomePageModule.framework/HomePageModule")) continue;
        const struct mach_header *header = _dyld_get_image_header(i);
        if (header) return (void *)header;
    }
    return NULL;
}

static uint32_t EB137FieldOffset(Class cls, NSUInteger vectorWordOffset, NSUInteger fieldIndex) {
    if (!cls) return 0;
    uint8_t *metadata = (uint8_t *)(__bridge void *)cls;
    uint32_t *vector = (uint32_t *)(metadata + vectorWordOffset * sizeof(void *));
    return vector[fieldIndex];
}

static BOOL EB137PointerIsInstanceOf(void *object, Class expected) {
    if (!object || !expected) return NO;
    uintptr_t firstWord = 0;
    @try {
        firstWord = *(uintptr_t *)object;
    } @catch (__unused NSException *exception) {
        return NO;
    }
    const uintptr_t mask = 0x0000FFFFFFFFFFFFULL;
    return (firstWord & mask) == (((uintptr_t)(__bridge void *)expected) & mask);
}

typedef struct {
    UIViewController *controller;
    void *viewModel;
    void *modelManager;
    uint32_t vmNeedsRefreshOffset;
    uint32_t vmIsRefreshingOffset;
    uint32_t vmUseCaseOffset;
    uint32_t managerIsRetrievingOffset;
    uint8_t needsRefresh;
    uint8_t isRefreshing;
    uint8_t useCase;
    uint8_t isRetrieving;
} EB137State;

static BOOL EB137ReadState(EB137State *state, NSString *phase) {
    if (!state) return NO;
    memset(state, 0, sizeof(*state));

    UIViewController *vc = EB137FindVLP();
    if (!vc) {
        EB137Log(@"HOME_STATE137 phase=%@ controller=not_found", phase);
        return NO;
    }
    state->controller = vc;

    Class baseClass = NSClassFromString(@"HomePageModule.VerticalLandingBaseViewController");
    if (!baseClass) baseClass = NSClassFromString(@"_TtC14HomePageModule33VerticalLandingBaseViewController");
    Class viewModelClass = NSClassFromString(@"HomePageModule.VerticalLandingPageViewModel");
    if (!viewModelClass) viewModelClass = NSClassFromString(@"_TtC14HomePageModule28VerticalLandingPageViewModel");
    Class managerClass = NSClassFromString(@"HomePageModule.VerticalLandingPageModelManager");
    if (!managerClass) managerClass = NSClassFromString(@"_TtC14HomePageModule31VerticalLandingPageModelManager");

    if (!baseClass || !viewModelClass || !managerClass) {
        EB137Log(@"HOME_STATE137 phase=%@ missing_classes base=%@ vm=%@ manager=%@",
                 phase, baseClass ? NSStringFromClass(baseClass) : @"nil",
                 viewModelClass ? NSStringFromClass(viewModelClass) : @"nil",
                 managerClass ? NSStringFromClass(managerClass) : @"nil");
        return NO;
    }

    // Swift class descriptor values from the supplied eBay 6.96 HomePageModule:
    // VerticalLandingBaseViewController FieldOffsetVectorOffset = 14 words.
    // VerticalLandingPageViewModel / ModelManager = 10 words.
    uint32_t baseViewModelOffset = EB137FieldOffset(baseClass, 14, 0);
    uint8_t *baseField = (uint8_t *)(__bridge void *)vc + baseViewModelOffset;
    void *viewModel = *(void **)baseField;

    uint32_t vmModelManagerOffset = EB137FieldOffset(viewModelClass, 10, 0);
    uint32_t vmNeedsRefreshOffset = EB137FieldOffset(viewModelClass, 10, 1);
    uint32_t vmIsRefreshingOffset = EB137FieldOffset(viewModelClass, 10, 2);
    uint32_t vmUseCaseOffset = EB137FieldOffset(viewModelClass, 10, 3);

    BOOL vmOK = EB137PointerIsInstanceOf(viewModel, viewModelClass);
    if (!vmOK) {
        uintptr_t raw[5] = {0};
        memcpy(raw, baseField, sizeof(raw));
        EB137Log(@"HOME_STATE137 phase=%@ vm_invalid baseOffset=0x%x raw=%p,%p,%p,%p,%p",
                 phase, baseViewModelOffset,
                 (void *)raw[0], (void *)raw[1], (void *)raw[2], (void *)raw[3], (void *)raw[4]);
        return NO;
    }

    state->viewModel = viewModel;
    state->vmNeedsRefreshOffset = vmNeedsRefreshOffset;
    state->vmIsRefreshingOffset = vmIsRefreshingOffset;
    state->vmUseCaseOffset = vmUseCaseOffset;
    state->needsRefresh = *((uint8_t *)viewModel + vmNeedsRefreshOffset);
    state->isRefreshing = *((uint8_t *)viewModel + vmIsRefreshingOffset);
    state->useCase = *((uint8_t *)viewModel + vmUseCaseOffset);

    uint8_t *managerExistential = (uint8_t *)viewModel + vmModelManagerOffset;
    void *modelManager = *(void **)managerExistential;
    BOOL managerOK = EB137PointerIsInstanceOf(modelManager, managerClass);

    uint32_t managerSubjectOffset = EB137FieldOffset(managerClass, 10, 0);
    uint32_t managerFeedSubjectOffset = EB137FieldOffset(managerClass, 10, 1);
    uint32_t managerIsRetrievingOffset = EB137FieldOffset(managerClass, 10, 2);
    uint32_t managerRequestFactoryOffset = EB137FieldOffset(managerClass, 10, 4);
    uint32_t managerNetworkerOffset = EB137FieldOffset(managerClass, 10, 5);
    uint32_t managerTransformOffset = EB137FieldOffset(managerClass, 10, 6);

    state->modelManager = managerOK ? modelManager : NULL;
    state->managerIsRetrievingOffset = managerIsRetrievingOffset;
    state->isRetrieving = managerOK ? *((uint8_t *)modelManager + managerIsRetrievingOffset) : 0xFF;

    void *subject = managerOK ? *(void **)((uint8_t *)modelManager + managerSubjectOffset) : NULL;
    void *feedSubject = managerOK ? *(void **)((uint8_t *)modelManager + managerFeedSubjectOffset) : NULL;
    void *requestFactory = managerOK ? *(void **)((uint8_t *)modelManager + managerRequestFactoryOffset) : NULL;
    void *networker = managerOK ? *(void **)((uint8_t *)modelManager + managerNetworkerOffset) : NULL;
    void *transform = managerOK ? *(void **)((uint8_t *)modelManager + managerTransformOffset) : NULL;

    EB137Log(@"HOME_STATE137 phase=%@ controller=%@ baseOff=0x%x vm=%p vmOffs=[mgr=0x%x needs=0x%x refreshing=0x%x useCase=0x%x] needs=%u refreshing=%u useCase=%u manager=%p managerOK=%d retrieving=%u mgrOffs=[subject=0x%x feed=0x%x retrieving=0x%x req=0x%x net=0x%x transform=0x%x] subject=%p feed=%p req=%p net=%p transform=%p",
             phase, NSStringFromClass([vc class]), baseViewModelOffset, viewModel,
             vmModelManagerOffset, vmNeedsRefreshOffset, vmIsRefreshingOffset, vmUseCaseOffset,
             state->needsRefresh, state->isRefreshing, state->useCase,
             modelManager, managerOK, state->isRetrieving,
             managerSubjectOffset, managerFeedSubjectOffset, managerIsRetrievingOffset,
             managerRequestFactoryOffset, managerNetworkerOffset, managerTransformOffset,
             subject, feedSubject, requestFactory, networker, transform);

    // Also dump the Published wrapper storage words. This lets us see whether the
    // model result reaches ViewModel even if ComponentUI never receives sections.
    NSArray<NSNumber *> *publishedIndexes = @[@6, @7, @9]; // _isLoading, _sections, _pageError
    NSArray<NSString *> *publishedNames = @[@"isLoading", @"sections", @"pageError"];
    for (NSUInteger i = 0; i < publishedIndexes.count; i++) {
        uint32_t off = EB137FieldOffset(viewModelClass, 10, publishedIndexes[i].unsignedIntegerValue);
        uintptr_t words[4] = {0};
        memcpy(words, (uint8_t *)viewModel + off, sizeof(words));
        EB137Log(@"HOME_STATE137 phase=%@ published=%@ off=0x%x words=%p,%p,%p,%p",
                 phase, publishedNames[i], off,
                 (void *)words[0], (void *)words[1], (void *)words[2], (void *)words[3]);
    }

    return YES;
}

static void EB137RebindAndRefetch(void) {
    if (EB137DidRebind) return;

    EB137State state;
    if (!EB137ReadState(&state, @"pre_rebind")) return;
    if (!state.viewModel) return;

    void *base = EB137HomeImageBase();
    if (!base) {
        EB137Log(@"HOME_REBIND137 image_base_not_found");
        return;
    }

    // Reverse engineered from the supplied 6.96 HomePageModule:
    // 0xF462C = ViewModel publisher/subscription setup.
    // 0xF46C4 = ViewModel fetch routine (checks isRefreshing, then invokes ModelManager).
    void *setupFunction = (uint8_t *)base + 0xF462C;
    void *fetchFunction = (uint8_t *)base + 0xF46C4;

    EB137DidRebind = YES;
    EB137Log(@"HOME_REBIND137 begin base=%p vm=%p setup=%p fetch=%p before_refreshing=%u before_retrieving=%u useCase=%u",
             base, state.viewModel, setupFunction, fetchFunction,
             state.isRefreshing, state.isRetrieving, state.useCase);

    EB137CallSwiftSelf0(state.viewModel, setupFunction);
    EB137Log(@"HOME_REBIND137 setup_called=1");

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.15 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        EB137CallSwiftSelf0(state.viewModel, fetchFunction);
        EB137Log(@"HOME_REBIND137 fetch_called=1");
        EB137State after;
        EB137ReadState(&after, @"post_fetch");
    });
}

%ctor {
    @autoreleasepool {
        if (![[[NSBundle mainBundle] bundleIdentifier] isEqualToString:@"com.ebay.iphone"]) return;

        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.25 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            EB137RebindAndRefetch();
        });
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(4.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            EB137State state; EB137ReadState(&state, @"4s");
        });
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(8.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            EB137State state; EB137ReadState(&state, @"8s");
        });
    }
}
