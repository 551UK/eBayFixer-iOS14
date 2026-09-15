#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <substrate.h>

static BOOL EB129Installed = NO;
static void (*EB129OrigViewDidAppear)(id, SEL, BOOL) = NULL;
static void (*EB129OrigStartLoading)(id, SEL) = NULL;
static void (*EB129OrigStopLoading)(id, SEL) = NULL;

static NSString *EB129LogPath(void) {
    NSArray *paths = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
    NSString *dir = paths.firstObject ?: NSTemporaryDirectory();
    return [dir stringByAppendingPathComponent:@"eBayFixer.log"];
}

static void EB129Log(NSString *format, ...) {
    if (!format) return;
    va_list args;
    va_start(args, format);
    NSString *message = [[NSString alloc] initWithFormat:format arguments:args];
    va_end(args);
    if (!message.length) return;

    NSString *path = EB129LogPath();
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

static void EB129CollectCollections(UIView *view, NSMutableArray<UICollectionView *> *out) {
    if (!view || !out) return;
    if ([view isKindOfClass:[UICollectionView class]]) [out addObject:(UICollectionView *)view];
    for (UIView *child in view.subviews) EB129CollectCollections(child, out);
}

static void EB129ProbeCollections(id controller, NSString *phase) {
    if (!controller || ![controller respondsToSelector:@selector(view)]) return;
    UIView *root = ((UIView *(*)(id, SEL))objc_msgSend)(controller, @selector(view));
    NSMutableArray<UICollectionView *> *collections = [NSMutableArray array];
    EB129CollectCollections(root, collections);

    if (!collections.count) {
        EB129Log(@"HOME_RENDER129 phase=%@ collections=0", phase ?: @"-");
        return;
    }

    NSMutableArray<NSString *> *summaries = [NSMutableArray array];
    NSUInteger index = 0;
    for (UICollectionView *cv in collections) {
        NSInteger sections = 0;
        NSMutableArray<NSNumber *> *items = [NSMutableArray array];
        @try {
            sections = [cv numberOfSections];
            NSInteger capped = MIN(sections, 12);
            for (NSInteger s = 0; s < capped; s++) {
                [items addObject:@([cv numberOfItemsInSection:s])];
            }
        } @catch (__unused NSException *exception) {}
        [summaries addObject:[NSString stringWithFormat:@"%lu:%@ sec=%ld items=%@ hidden=%d alpha=%.2f",
                              (unsigned long)index,
                              NSStringFromClass([cv class]),
                              (long)sections,
                              items,
                              cv.hidden,
                              cv.alpha]];
        index++;
    }
    EB129Log(@"HOME_RENDER129 phase=%@ collections=%lu %@",
             phase ?: @"-", (unsigned long)collections.count,
             [summaries componentsJoinedByString:@" | "]);
}

static void EB129ReleaseLoader(id controller, NSString *reason) {
    if (!controller) return;

    BOOL customEnabled = NO;
    SEL enabledSel = NSSelectorFromString(@"isCustomLoadingScreenEnabled");
    if ([controller respondsToSelector:enabledSel]) {
        customEnabled = ((BOOL (*)(id, SEL))objc_msgSend)(controller, enabledSel);
    }

    EB129Log(@"HOME_RENDER129 release_loader reason=%@ customEnabled=%d class=%@",
             reason ?: @"-", customEnabled, NSStringFromClass([controller class]));

    SEL stopSel = NSSelectorFromString(@"stopAnimatingCustomLoadingScreen");
    if ([controller respondsToSelector:stopSel]) {
        ((void (*)(id, SEL))objc_msgSend)(controller, stopSel);
    }

    [[NSNotificationCenter defaultCenter] postNotificationName:@"StopAnimatingHomePageLoadingScreenNotification"
                                                        object:nil];

    if ([controller respondsToSelector:@selector(view)]) {
        UIView *view = ((UIView *(*)(id, SEL))objc_msgSend)(controller, @selector(view));
        [view setNeedsLayout];
        [view layoutIfNeeded];
    }
}

static void EB129StartLoading(id self, SEL _cmd) {
    EB129Log(@"HOME_RENDER129 native_start_loader class=%@", NSStringFromClass([self class]));
    if (EB129OrigStartLoading) EB129OrigStartLoading(self, _cmd);
}

static void EB129StopLoading(id self, SEL _cmd) {
    EB129Log(@"HOME_RENDER129 native_stop_loader class=%@", NSStringFromClass([self class]));
    if (EB129OrigStopLoading) EB129OrigStopLoading(self, _cmd);
}

static void EB129ViewDidAppear(id self, SEL _cmd, BOOL animated) {
    if (EB129OrigViewDidAppear) EB129OrigViewDidAppear(self, _cmd, animated);

    EB129Log(@"HOME_RENDER129 vlp_viewDidAppear class=%@", NSStringFromClass([self class]));

    id controller = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.5 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        EB129ProbeCollections(controller, @"before_release_2.5s");
        EB129ReleaseLoader(controller, @"home_response_grace_2.5s");
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.35 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            EB129ProbeCollections(controller, @"after_release_2.85s");
        });
    });

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(5.0 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        EB129ProbeCollections(controller, @"before_release_5s");
        EB129ReleaseLoader(controller, @"fallback_5s");
    });
}

static void EB129Install(void) {
    if (EB129Installed) return;
    Class cls = NSClassFromString(@"_TtC14HomePageModule37HomeVerticalLandingPageViewController");
    if (!cls) return;

    Method appear = class_getInstanceMethod(cls, @selector(viewDidAppear:));
    Method start = class_getInstanceMethod(cls, NSSelectorFromString(@"startAnimatingCustomLoadingScreen"));
    Method stop = class_getInstanceMethod(cls, NSSelectorFromString(@"stopAnimatingCustomLoadingScreen"));
    if (!appear || !start || !stop) {
        EB129Log(@"HOME_RENDER129 install_missing appear=%d start=%d stop=%d", !!appear, !!start, !!stop);
        return;
    }

    MSHookMessageEx(cls, @selector(viewDidAppear:), (IMP)EB129ViewDidAppear, (IMP *)&EB129OrigViewDidAppear);
    MSHookMessageEx(cls, NSSelectorFromString(@"startAnimatingCustomLoadingScreen"), (IMP)EB129StartLoading, (IMP *)&EB129OrigStartLoading);
    MSHookMessageEx(cls, NSSelectorFromString(@"stopAnimatingCustomLoadingScreen"), (IMP)EB129StopLoading, (IMP *)&EB129OrigStopLoading);
    EB129Installed = YES;
    EB129Log(@"HOME_RENDER129 hooks_installed class=%@", NSStringFromClass(cls));
}

%ctor {
    @autoreleasepool {
        if (![[[NSBundle mainBundle] bundleIdentifier] isEqualToString:@"com.ebay.iphone"]) return;
        EB129Install();
        for (NSNumber *delay in @[@0.01, @0.05, @0.15, @0.4, @1.0]) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay.doubleValue * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{ EB129Install(); });
        }
    }
}
