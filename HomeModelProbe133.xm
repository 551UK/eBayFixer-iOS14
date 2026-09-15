#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>

static NSString *EB133LogPath(void) {
    NSArray *paths = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
    NSString *dir = paths.firstObject ?: NSTemporaryDirectory();
    return [dir stringByAppendingPathComponent:@"eBayFixer.log"];
}

static void EB133Log(NSString *format, ...) {
    if (!format) return;
    va_list args;
    va_start(args, format);
    NSString *message = [[NSString alloc] initWithFormat:format arguments:args];
    va_end(args);
    if (!message.length) return;

    NSString *path = EB133LogPath();
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

static BOOL EB133IsHomeVLPObject(id object) {
    if (![object isKindOfClass:[NSDictionary class]]) return NO;
    NSDictionary *root = (NSDictionary *)object;
    NSDictionary *meta = [root[@"meta"] isKindOfClass:[NSDictionary class]] ? root[@"meta"] : nil;
    NSDictionary *pageTemplate = [meta[@"pageTemplate"] isKindOfClass:[NSDictionary class]] ? meta[@"pageTemplate"] : nil;
    if (![[pageTemplate[@"templateId"] description] isEqualToString:@"VerticalLandingPage"]) return NO;

    NSDictionary *modules = [root[@"modules"] isKindOfClass:[NSDictionary class]] ? root[@"modules"] : nil;
    return modules.count > 0;
}

static void EB133SaveLiveHome(id object) {
    if (!EB133IsHomeVLPObject(object)) return;
    NSError *error = nil;
    NSData *data = [NSJSONSerialization dataWithJSONObject:object options:0 error:&error];
    if (!data.length) {
        EB133Log(@"HOME_MODEL133 adapted_json_save_failed error=%@/%ld", error.domain ?: @"none", (long)error.code);
        return;
    }

    NSArray *paths = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
    NSString *dir = paths.firstObject ?: NSTemporaryDirectory();
    NSString *path = [dir stringByAppendingPathComponent:@"eBayFixer-HOME-adapted-live.json"];
    [data writeToFile:path atomically:YES];

    NSDictionary *modules = [(NSDictionary *)object objectForKey:@"modules"];
    NSMutableArray *summary = [NSMutableArray array];
    for (id key in modules) {
        NSDictionary *module = [modules[key] isKindOfClass:[NSDictionary class]] ? modules[key] : nil;
        if (!module) continue;
        NSArray *containers = [module[@"containers"] isKindOfClass:[NSArray class]] ? module[@"containers"] : nil;
        NSUInteger cardContainers = 0;
        if (containers.count && [containers.firstObject isKindOfClass:[NSDictionary class]]) {
            id cards = containers.firstObject[@"cardContainers"];
            if ([cards isKindOfClass:[NSArray class]]) cardContainers = [cards count];
        }
        [summary addObject:[NSString stringWithFormat:@"%@:%@ containers=%lu cards=%lu",
                            [key description], [module[@"_type"] description] ?: @"-",
                            (unsigned long)containers.count, (unsigned long)cardContainers]];
    }
    EB133Log(@"HOME_MODEL133 adapted_json bytes=%lu modules=%lu %@",
             (unsigned long)data.length, (unsigned long)modules.count,
             [summary componentsJoinedByString:@" | "]);
}

static BOOL EB133InterestingClassName(NSString *name) {
    if (!name.length) return NO;
    NSArray *needles = @[@"VerticalLanding", @"HomeVerticalLanding", @"NavigationBarModuleTransformer",
                         @"RecommendedSeller", @"HomePageData", @"HomeDataManager"];
    for (NSString *needle in needles) if ([name containsString:needle]) return YES;
    return NO;
}

static BOOL EB133InterestingMethodName(NSString *name) {
    NSString *lower = name.lowercaseString ?: @"";
    NSArray *needles = @[@"transform", @"model", @"section", @"module", @"fetch", @"load",
                         @"response", @"error", @"complete", @"update", @"data"];
    for (NSString *needle in needles) if ([lower containsString:needle]) return YES;
    return NO;
}

static void EB133DumpRuntimeClasses(void) {
    int count = objc_getClassList(NULL, 0);
    if (count <= 0) return;
    Class *classes = (__unsafe_unretained Class *)calloc((size_t)count, sizeof(Class));
    count = objc_getClassList(classes, count);

    NSUInteger matched = 0;
    for (int i = 0; i < count; i++) {
        Class cls = classes[i];
        NSString *name = NSStringFromClass(cls);
        if (!EB133InterestingClassName(name)) continue;
        matched++;

        unsigned int methodCount = 0;
        Method *methods = class_copyMethodList(cls, &methodCount);
        NSMutableArray *methodNames = [NSMutableArray array];
        for (unsigned int m = 0; m < methodCount; m++) {
            NSString *selectorName = NSStringFromSelector(method_getName(methods[m]));
            if (EB133InterestingMethodName(selectorName)) [methodNames addObject:selectorName];
        }
        if (methods) free(methods);

        unsigned int ivarCount = 0;
        Ivar *ivars = class_copyIvarList(cls, &ivarCount);
        NSMutableArray *ivarNames = [NSMutableArray array];
        for (unsigned int v = 0; v < ivarCount; v++) {
            const char *n = ivar_getName(ivars[v]);
            const char *t = ivar_getTypeEncoding(ivars[v]);
            if (n) [ivarNames addObject:[NSString stringWithFormat:@"%s:%s", n, t ?: "?"]];
        }
        if (ivars) free(ivars);

        EB133Log(@"HOME_MODEL133 runtime class=%@ super=%@ methods=%@ ivars=%@",
                 name, NSStringFromClass(class_getSuperclass(cls)) ?: @"-",
                 methodNames, ivarNames);
    }
    free(classes);
    EB133Log(@"HOME_MODEL133 runtime_scan matched=%lu", (unsigned long)matched);
}

static UIViewController *EB133FindVLPInController(UIViewController *vc) {
    if (!vc) return nil;
    if ([NSStringFromClass([vc class]) containsString:@"HomeVerticalLandingPageViewController"]) return vc;
    if (vc.presentedViewController) {
        UIViewController *found = EB133FindVLPInController(vc.presentedViewController);
        if (found) return found;
    }
    if ([vc isKindOfClass:[UINavigationController class]]) {
        UIViewController *found = EB133FindVLPInController([(UINavigationController *)vc visibleViewController]);
        if (found) return found;
    }
    if ([vc isKindOfClass:[UITabBarController class]]) {
        UIViewController *found = EB133FindVLPInController([(UITabBarController *)vc selectedViewController]);
        if (found) return found;
    }
    for (UIViewController *child in vc.childViewControllers) {
        UIViewController *found = EB133FindVLPInController(child);
        if (found) return found;
    }
    return nil;
}

static UIViewController *EB133FindVLPController(void) {
    UIApplication *app = [UIApplication sharedApplication];
    for (UIWindow *window in app.windows) {
        UIViewController *found = EB133FindVLPInController(window.rootViewController);
        if (found) return found;
    }
    return nil;
}

static void EB133CollectCollections(UIView *view, NSMutableArray<UICollectionView *> *out) {
    if (!view) return;
    if ([view isKindOfClass:[UICollectionView class]]) [out addObject:(UICollectionView *)view];
    for (UIView *child in view.subviews) EB133CollectCollections(child, out);
}

static NSString *EB133DescribeValue(id value) {
    if (!value) return @"nil";
    NSString *cls = NSStringFromClass([value class]) ?: @"?";
    if ([value respondsToSelector:@selector(count)]) {
        @try { return [NSString stringWithFormat:@"%@ count=%lu", cls, (unsigned long)[value count]]; }
        @catch (__unused NSException *exception) {}
    }
    return cls;
}

static void EB133ProbeVLP(NSString *phase) {
    UIViewController *vc = EB133FindVLPController();
    if (!vc) {
        EB133Log(@"HOME_MODEL133 phase=%@ controller=not_found", phase);
        return;
    }

    NSArray *keys = @[@"sectionModels", @"sections", @"viewModel", @"modelManager", @"dataManager",
                      @"displayModel", @"displayModels", @"moduleModels", @"modules", @"pageModel", @"contentModel"];
    NSMutableArray *values = [NSMutableArray array];
    for (NSString *key in keys) {
        @try {
            id value = [vc valueForKey:key];
            [values addObject:[NSString stringWithFormat:@"%@=%@", key, EB133DescribeValue(value)]];
        } @catch (__unused NSException *exception) {}
    }

    NSMutableArray<UICollectionView *> *collections = [NSMutableArray array];
    EB133CollectCollections(vc.view, collections);
    NSMutableArray *collectionSummary = [NSMutableArray array];
    NSUInteger index = 0;
    for (UICollectionView *cv in collections) {
        NSInteger sections = 0;
        NSMutableArray *items = [NSMutableArray array];
        @try {
            sections = [cv numberOfSections];
            for (NSInteger s = 0; s < MIN(sections, 12); s++) [items addObject:@([cv numberOfItemsInSection:s])];
        } @catch (__unused NSException *exception) {}
        [collectionSummary addObject:[NSString stringWithFormat:@"%lu:%@ ds=%@ sec=%ld items=%@ hidden=%d alpha=%.2f",
                                      (unsigned long)index, NSStringFromClass([cv class]),
                                      cv.dataSource ? NSStringFromClass([cv.dataSource class]) : @"nil",
                                      (long)sections, items, cv.hidden, cv.alpha]];
        index++;
    }

    EB133Log(@"HOME_MODEL133 phase=%@ controller=%@ kvc=[%@] collections=%lu [%@]",
             phase, NSStringFromClass([vc class]), [values componentsJoinedByString:@"; "],
             (unsigned long)collections.count, [collectionSummary componentsJoinedByString:@" | "]);

    Class cls = [vc class];
    for (NSUInteger depth = 0; cls && depth < 4; depth++, cls = class_getSuperclass(cls)) {
        unsigned int ivarCount = 0;
        Ivar *ivars = class_copyIvarList(cls, &ivarCount);
        NSMutableArray *objects = [NSMutableArray array];
        for (unsigned int i = 0; i < ivarCount; i++) {
            const char *type = ivar_getTypeEncoding(ivars[i]);
            const char *name = ivar_getName(ivars[i]);
            if (!type || type[0] != '@' || !name) continue;
            @try {
                id value = object_getIvar(vc, ivars[i]);
                if (value) [objects addObject:[NSString stringWithFormat:@"%s=%@", name, EB133DescribeValue(value)]];
            } @catch (__unused NSException *exception) {}
        }
        if (ivars) free(ivars);
        if (objects.count) EB133Log(@"HOME_MODEL133 ivars class=%@ %@", NSStringFromClass(cls), objects);
    }
}

%hook NSJSONSerialization

+ (id)JSONObjectWithData:(NSData *)data options:(NSJSONReadingOptions)opt error:(NSError **)error {
    id object = %orig;
    EB133SaveLiveHome(object);
    return object;
}

%end

%ctor {
    @autoreleasepool {
        if (![[[NSBundle mainBundle] bundleIdentifier] isEqualToString:@"com.ebay.iphone"]) return;
        %init;

        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.2 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            EB133DumpRuntimeClasses();
        });
        NSArray *phases = @[@[@2.0, @"2s"], @[@4.0, @"4s"], @[@8.0, @"8s"]];
        for (NSArray *entry in phases) {
            NSTimeInterval delay = [entry[0] doubleValue];
            NSString *phase = entry[1];
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                EB133ProbeVLP(phase);
            });
        }
    }
}
