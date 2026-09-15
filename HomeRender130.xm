#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <substrate.h>

static BOOL EB130Installed = NO;
static void (*EB130OrigViewDidAppear)(id, SEL, BOOL) = NULL;
static void (*EB130OrigStopLoading)(id, SEL) = NULL;

static NSString *EB130LogPath(void) {
    NSArray *paths = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
    NSString *dir = paths.firstObject ?: NSTemporaryDirectory();
    return [dir stringByAppendingPathComponent:@"eBayFixer.log"];
}

static void EB130Log(NSString *format, ...) {
    if (!format) return;
    va_list args;
    va_start(args, format);
    NSString *message = [[NSString alloc] initWithFormat:format arguments:args];
    va_end(args);
    if (!message.length) return;

    NSString *path = EB130LogPath();
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

static BOOL EB130CustomLoadingDisabled(id self, SEL _cmd) {
    EB130Log(@"HOME_RENDER130 custom_loading_enabled requested -> 0 class=%@", NSStringFromClass([self class]));
    return NO;
}

static void EB130StartLoadingBlocked(id self, SEL _cmd) {
    EB130Log(@"HOME_RENDER130 start_loader BLOCKED class=%@", NSStringFromClass([self class]));
    // Deliberately do not call the original implementation. 6.96's custom
    // skeleton can otherwise remain above a successfully routed VLP screen.
}

static void EB130StopLoading(id self, SEL _cmd) {
    EB130Log(@"HOME_RENDER130 stop_loader class=%@", NSStringFromClass([self class]));
    if (EB130OrigStopLoading) EB130OrigStopLoading(self, _cmd);
}

static void EB130CollectCollections(UIView *view, NSMutableArray<UICollectionView *> *out) {
    if (!view || !out) return;
    if ([view isKindOfClass:[UICollectionView class]]) [out addObject:(UICollectionView *)view];
    for (UIView *child in view.subviews) EB130CollectCollections(child, out);
}

static void EB130ForceReveal(id controller, NSString *phase) {
    if (!controller || ![controller respondsToSelector:@selector(view)]) return;

    SEL stopSel = NSSelectorFromString(@"stopAnimatingCustomLoadingScreen");
    if ([controller respondsToSelector:stopSel]) {
        ((void (*)(id, SEL))objc_msgSend)(controller, stopSel);
    }
    [[NSNotificationCenter defaultCenter] postNotificationName:@"StopAnimatingHomePageLoadingScreenNotification" object:nil];

    UIView *root = ((UIView *(*)(id, SEL))objc_msgSend)(controller, @selector(view));
    NSMutableArray<UICollectionView *> *collections = [NSMutableArray array];
    EB130CollectCollections(root, collections);

    NSMutableArray<NSString *> *summaries = [NSMutableArray array];
    NSUInteger idx = 0;
    for (UICollectionView *cv in collections) {
        @try {
            [cv reloadData];
            [cv layoutIfNeeded];
        } @catch (__unused NSException *exception) {}

        NSInteger sections = 0;
        NSMutableArray<NSNumber *> *items = [NSMutableArray array];
        @try {
            sections = [cv numberOfSections];
            NSInteger capped = MIN(sections, 16);
            for (NSInteger section = 0; section < capped; section++) {
                [items addObject:@([cv numberOfItemsInSection:section])];
            }
        } @catch (__unused NSException *exception) {}

        NSString *dataSourceClass = cv.dataSource ? NSStringFromClass([cv.dataSource class]) : @"nil";
        NSString *delegateClass = cv.delegate ? NSStringFromClass([cv.delegate class]) : @"nil";
        [summaries addObject:[NSString stringWithFormat:@"%lu:%@ ds=%@ del=%@ sec=%ld items=%@ hidden=%d alpha=%.2f",
                              (unsigned long)idx,
                              NSStringFromClass([cv class]),
                              dataSourceClass,
                              delegateClass,
                              (long)sections,
                              items,
                              cv.hidden,
                              cv.alpha]];
        idx++;
    }

    [root setNeedsLayout];
    [root layoutIfNeeded];

    EB130Log(@"HOME_RENDER130 phase=%@ collections=%lu %@",
             phase ?: @"-",
             (unsigned long)collections.count,
             [summaries componentsJoinedByString:@" | "]);
}

static void EB130ViewDidAppear(id self, SEL _cmd, BOOL animated) {
    if (EB130OrigViewDidAppear) EB130OrigViewDidAppear(self, _cmd, animated);
    EB130Log(@"HOME_RENDER130 vlp_viewDidAppear class=%@", NSStringFromClass([self class]));

    id controller = self;
    for (NSNumber *delay in @[@0.15, @0.75, @1.5, @3.0, @5.0]) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay.doubleValue * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            EB130ForceReveal(controller, [NSString stringWithFormat:@"reveal_%.2fs", delay.doubleValue]);
        });
    }
}

static void EB130Install(void) {
    if (EB130Installed) return;
    Class cls = NSClassFromString(@"_TtC14HomePageModule37HomeVerticalLandingPageViewController");
    if (!cls) return;

    SEL appearSel = @selector(viewDidAppear:);
    SEL enabledSel = NSSelectorFromString(@"isCustomLoadingScreenEnabled");
    SEL startSel = NSSelectorFromString(@"startAnimatingCustomLoadingScreen");
    SEL stopSel = NSSelectorFromString(@"stopAnimatingCustomLoadingScreen");

    Method appear = class_getInstanceMethod(cls, appearSel);
    Method enabled = class_getInstanceMethod(cls, enabledSel);
    Method start = class_getInstanceMethod(cls, startSel);
    Method stop = class_getInstanceMethod(cls, stopSel);

    if (!appear || !enabled || !start || !stop) {
        EB130Log(@"HOME_RENDER130 install_missing appear=%d enabled=%d start=%d stop=%d",
                 !!appear, !!enabled, !!start, !!stop);
        return;
    }

    MSHookMessageEx(cls, appearSel, (IMP)EB130ViewDidAppear, (IMP *)&EB130OrigViewDidAppear);
    MSHookMessageEx(cls, enabledSel, (IMP)EB130CustomLoadingDisabled, NULL);
    MSHookMessageEx(cls, startSel, (IMP)EB130StartLoadingBlocked, NULL);
    MSHookMessageEx(cls, stopSel, (IMP)EB130StopLoading, (IMP *)&EB130OrigStopLoading);

    EB130Installed = YES;
    EB130Log(@"HOME_RENDER130 hooks_installed class=%@ skeleton_disabled=1", NSStringFromClass(cls));
}

%ctor {
    @autoreleasepool {
        if (![[[NSBundle mainBundle] bundleIdentifier] isEqualToString:@"com.ebay.iphone"]) return;
        EB130Install();
        for (NSNumber *delay in @[@0.01, @0.05, @0.15, @0.40, @1.0]) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay.doubleValue * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{ EB130Install(); });
        }
    }
}
