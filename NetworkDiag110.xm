#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <substrate.h>

static NSString *EB110LogPath(void) {
    NSArray *paths = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
    NSString *dir = paths.firstObject ?: NSTemporaryDirectory();
    return [dir stringByAppendingPathComponent:@"eBayFixer.log"];
}

static void EB110Log(NSString *format, ...) {
    va_list args;
    va_start(args, format);
    NSString *message = [[NSString alloc] initWithFormat:format arguments:args];
    va_end(args);
    if (!message) return;
    NSString *line = [NSString stringWithFormat:@"%@ %@\n", [NSDate date], message];
    NSData *data = [line dataUsingEncoding:NSUTF8StringEncoding];
    NSString *path = EB110LogPath();
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

static NSString *EB110Kind(NSURL *url) {
    NSString *path = url.path.lowercaseString ?: @"";
    NSString *host = url.host.lowercaseString ?: @"";
    if ([host containsString:@"mobidcsng.ebay.com"] && [path containsString:@"/mobile/dcs/"]) return @"HOME_DCS";
    if ([path containsString:@"/experience/shopping/v1/homepage/user_segmentation"] ||
        [path containsString:@"homepage/user_segmentation"] ||
        ([path containsString:@"vlp"] && [path containsString:@"segmentation"])) return @"HOME_SEGMENTATION";
    if ([path containsString:@"/experience/vertical_landing/v1/module_provider"]) return @"HOME_PROVIDER";
    if ([path containsString:@"/experience/listing_details/v2/module_provider"] ||
        [path containsString:@"/experience/listing_details/v2/preview_draft_listing"] ||
        [path containsString:@"/experience/listing_details/v2/quick_view"]) return @"ITEM_PROVIDER";
    if ([path containsString:@"/experience/shopping/v1/home"] ||
        [path containsString:@"/experience/vertical_landing/v1/get_homepage"]) return @"HOME";
    if ([path containsString:@"/experience/listing_details/"] ||
        [path containsString:@"/view_item"]) return @"ITEM";
    if ([path containsString:@"/experience/search/"] ||
        [path containsString:@"search_results"]) return @"SEARCH";
    return nil;
}

static void EB110Poll(NSURLSessionTask *task, NSString *kind, NSTimeInterval delay) {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        NSURLResponse *response = task.response;
        NSInteger status = [response isKindOfClass:[NSHTTPURLResponse class]] ? [(NSHTTPURLResponse *)response statusCode] : 0;
        NSError *error = task.error;
        EB110Log(@"TASK %@ %.2fs state=%ld status=%ld received=%lld expected=%lld error=%@/%ld",
                 kind, delay, (long)task.state, (long)status,
                 task.countOfBytesReceived, task.countOfBytesExpectedToReceive,
                 error.domain ?: @"none", (long)error.code);
    });
}

static UIViewController *EB134FindVLPInController(UIViewController *vc) {
    if (!vc) return nil;
    NSString *name = NSStringFromClass([vc class]) ?: @"";
    if ([name containsString:@"HomeVerticalLandingPageViewController"]) return vc;
    if (vc.presentedViewController) {
        UIViewController *found = EB134FindVLPInController(vc.presentedViewController);
        if (found) return found;
    }
    if ([vc isKindOfClass:[UINavigationController class]]) {
        UIViewController *found = EB134FindVLPInController([(UINavigationController *)vc visibleViewController]);
        if (found) return found;
    }
    if ([vc isKindOfClass:[UITabBarController class]]) {
        UIViewController *found = EB134FindVLPInController([(UITabBarController *)vc selectedViewController]);
        if (found) return found;
    }
    for (UIViewController *child in vc.childViewControllers) {
        UIViewController *found = EB134FindVLPInController(child);
        if (found) return found;
    }
    return nil;
}

static UIViewController *EB134FindVLP(void) {
    for (UIWindow *window in [UIApplication sharedApplication].windows) {
        UIViewController *found = EB134FindVLPInController(window.rootViewController);
        if (found) return found;
    }
    return nil;
}

static void EB134CollectCollections(UIView *view, NSMutableArray *result) {
    if (!view) return;
    if ([view isKindOfClass:[UICollectionView class]]) [result addObject:view];
    for (UIView *child in view.subviews) EB134CollectCollections(child, result);
}

static NSString *EB134Describe(id value) {
    if (!value) return @"nil";
    NSString *name = NSStringFromClass([value class]) ?: @"?";
    if ([value respondsToSelector:@selector(count)]) {
        @try { return [NSString stringWithFormat:@"%@ count=%lu", name, (unsigned long)[value count]]; }
        @catch (__unused NSException *e) {}
    }
    return name;
}

static void EB134Probe(NSString *phase) {
    UIViewController *vc = EB134FindVLP();
    if (!vc) {
        EB110Log(@"HOME_PIPE134 phase=%@ controller=not_found", phase);
        return;
    }

    NSMutableArray *values = [NSMutableArray array];
    for (NSString *key in @[@"sectionModels", @"sections", @"viewModel", @"modelManager", @"dataManager", @"displayModel", @"moduleModels", @"pageModel", @"contentModel"]) {
        @try {
            id value = [vc valueForKey:key];
            [values addObject:[NSString stringWithFormat:@"%@=%@", key, EB134Describe(value)]];
        } @catch (__unused NSException *e) {}
    }

    NSMutableArray *collections = [NSMutableArray array];
    EB134CollectCollections(vc.view, collections);
    NSMutableArray *summaries = [NSMutableArray array];
    NSUInteger idx = 0;
    for (UICollectionView *cv in collections) {
        NSInteger sections = 0;
        NSMutableArray *items = [NSMutableArray array];
        @try {
            sections = [cv numberOfSections];
            for (NSInteger s = 0; s < MIN(sections, 12); s++) [items addObject:@([cv numberOfItemsInSection:s])];
        } @catch (__unused NSException *e) {}
        [summaries addObject:[NSString stringWithFormat:@"%lu:%@ ds=%@ sec=%ld items=%@ hidden=%d alpha=%.2f",
                              (unsigned long)idx++, NSStringFromClass([cv class]),
                              cv.dataSource ? NSStringFromClass([cv.dataSource class]) : @"nil",
                              (long)sections, items, cv.hidden, cv.alpha]];
    }

    EB110Log(@"HOME_PIPE134 phase=%@ controller=%@ kvc=[%@] collections=%lu [%@]",
             phase, NSStringFromClass([vc class]), [values componentsJoinedByString:@"; "],
             (unsigned long)collections.count, [summaries componentsJoinedByString:@" | "]);
}

static void EB134DumpRelevantClasses(void) {
    int count = objc_getClassList(NULL, 0);
    if (count <= 0) return;
    Class *classes = (__unsafe_unretained Class *)calloc((size_t)count, sizeof(Class));
    count = objc_getClassList(classes, count);
    NSUInteger matched = 0;
    for (int i = 0; i < count; i++) {
        Class cls = classes[i];
        NSString *name = NSStringFromClass(cls) ?: @"";
        if (![name containsString:@"VerticalLanding"] && ![name containsString:@"HomeVerticalLanding"] && ![name containsString:@"HomePageData"] && ![name containsString:@"HomeDataManager"]) continue;
        matched++;
        unsigned int methodCount = 0;
        Method *methods = class_copyMethodList(cls, &methodCount);
        NSMutableArray *names = [NSMutableArray array];
        for (unsigned int m = 0; m < methodCount; m++) {
            NSString *sel = NSStringFromSelector(method_getName(methods[m])) ?: @"";
            NSString *lower = sel.lowercaseString;
            if ([lower containsString:@"section"] || [lower containsString:@"model"] || [lower containsString:@"fetch"] || [lower containsString:@"response"] || [lower containsString:@"transform"] || [lower containsString:@"data"] || [lower containsString:@"load"]) [names addObject:sel];
        }
        if (methods) free(methods);
        EB110Log(@"HOME_PIPE134 runtime class=%@ super=%@ methods=%@", name, NSStringFromClass(class_getSuperclass(cls)) ?: @"-", names);
    }
    free(classes);
    EB110Log(@"HOME_PIPE134 runtime_scan matched=%lu", (unsigned long)matched);
}

static BOOL (*EB134OrigCustomLoader)(id, SEL) = NULL;
static BOOL EB134CustomLoader(id self, SEL _cmd) {
    EB110Log(@"HOME_LOADING134 isCustomLoadingScreenEnabled original_bypassed=1");
    return NO;
}

static void (*EB134OrigViewDidAppear)(id, SEL, BOOL) = NULL;
static void EB134ViewDidAppear(id self, SEL _cmd, BOOL animated) {
    if (EB134OrigViewDidAppear) EB134OrigViewDidAppear(self, _cmd, animated);
    EB110Log(@"HOME_LOADING134 viewDidAppear force_stop_loader=1");
    SEL stopSel = NSSelectorFromString(@"stopAnimatingCustomLoadingScreen");
    if ([self respondsToSelector:stopSel]) {
        ((void(*)(id,SEL))objc_msgSend)(self, stopSel);
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            if ([self respondsToSelector:stopSel]) ((void(*)(id,SEL))objc_msgSend)(self, stopSel);
        });
    }
}

static void (*EB134OrigSetSectionsAnimated)(id, SEL, id, BOOL) = NULL;
static void EB134SetSectionsAnimated(id self, SEL _cmd, id models, BOOL animated) {
    NSUInteger count = [models respondsToSelector:@selector(count)] ? [models count] : 0;
    EB110Log(@"HOME_PIPE134 setSectionModels:animated class=%@ models=%@ count=%lu animated=%d", NSStringFromClass([self class]), EB134Describe(models), (unsigned long)count, animated);
    if (EB134OrigSetSectionsAnimated) EB134OrigSetSectionsAnimated(self, _cmd, models, animated);
}

static void (*EB134OrigDidComplete)(id, SEL, id, id) = NULL;
static void EB134DidComplete(id self, SEL _cmd, id manager, id fetch) {
    EB110Log(@"HOME_PIPE134 dataManager didComplete class=%@ manager=%@ fetch=%@", NSStringFromClass([self class]), EB134Describe(manager), EB134Describe(fetch));
    if (EB134OrigDidComplete) EB134OrigDidComplete(self, _cmd, manager, fetch);
}

static void (*EB134OrigDidError)(id, SEL, id, id) = NULL;
static void EB134DidError(id self, SEL _cmd, id manager, id error) {
    EB110Log(@"HOME_PIPE134 dataManager didError class=%@ manager=%@ error=%@", NSStringFromClass([self class]), EB134Describe(manager), [error description] ?: @"nil");
    if (EB134OrigDidError) EB134OrigDidError(self, _cmd, manager, error);
}

static BOOL EB134HooksInstalled = NO;
static void EB134InstallHooks(void) {
    if (EB134HooksInstalled) return;
    Class vlp = NSClassFromString(@"HomePageModule.HomeVerticalLandingPageViewController");
    if (!vlp) vlp = NSClassFromString(@"_TtC14HomePageModule37HomeVerticalLandingPageViewController");
    Class base = NSClassFromString(@"HomePageModule.VerticalLandingBaseViewController");
    if (!base) base = NSClassFromString(@"_TtC14HomePageModule33VerticalLandingBaseViewController");

    BOOL any = NO;
    if (vlp) {
        Method loader = class_getInstanceMethod(vlp, NSSelectorFromString(@"isCustomLoadingScreenEnabled"));
        if (loader) {
            MSHookMessageEx(vlp, NSSelectorFromString(@"isCustomLoadingScreenEnabled"), (IMP)EB134CustomLoader, (IMP *)&EB134OrigCustomLoader);
            any = YES;
        }
        Method appeared = class_getInstanceMethod(vlp, @selector(viewDidAppear:));
        if (appeared) {
            MSHookMessageEx(vlp, @selector(viewDidAppear:), (IMP)EB134ViewDidAppear, (IMP *)&EB134OrigViewDidAppear);
            any = YES;
        }
    }
    if (base) {
        SEL setSel = NSSelectorFromString(@"setSectionModels:animated:");
        if (class_getInstanceMethod(base, setSel)) {
            MSHookMessageEx(base, setSel, (IMP)EB134SetSectionsAnimated, (IMP *)&EB134OrigSetSectionsAnimated);
            any = YES;
        }
        SEL completeSel = NSSelectorFromString(@"dataManager:didCompleteFetch:");
        if (class_getInstanceMethod(base, completeSel)) {
            MSHookMessageEx(base, completeSel, (IMP)EB134DidComplete, (IMP *)&EB134OrigDidComplete);
            any = YES;
        }
        SEL errorSel = NSSelectorFromString(@"dataManager:didError:");
        if (class_getInstanceMethod(base, errorSel)) {
            MSHookMessageEx(base, errorSel, (IMP)EB134DidError, (IMP *)&EB134OrigDidError);
            any = YES;
        }
    }
    EB110Log(@"HOME_PIPE134 hook_install vlp=%@ base=%@ any=%d", vlp ? NSStringFromClass(vlp) : @"nil", base ? NSStringFromClass(base) : @"nil", any);
    if (any) EB134HooksInstalled = YES;
}

%hook NSURLSessionTask

- (void)resume {
    NSURLRequest *request = self.currentRequest ?: self.originalRequest;
    NSString *kind = EB110Kind(request.URL);
    if (kind) {
        EB110Log(@"REQ %@ %@", kind, request.URL.absoluteString ?: @"(nil)");
        for (NSNumber *delay in @[@0.25, @1.0, @2.0, @4.0, @8.0]) {
            EB110Poll(self, kind, delay.doubleValue);
        }
    }
    %orig;
}

%end

%ctor {
    if (![[[NSBundle mainBundle] bundleIdentifier] isEqualToString:@"com.ebay.iphone"]) return;
    [[NSFileManager defaultManager] removeItemAtPath:EB110LogPath() error:nil];
    %init;

    EB134InstallHooks();
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.20 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ EB134InstallHooks(); });
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.20 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ EB134DumpRelevantClasses(); });
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ EB134Probe(@"2s"); });
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(4.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ EB134Probe(@"4s"); });
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(8.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ EB134Probe(@"8s"); });
}
