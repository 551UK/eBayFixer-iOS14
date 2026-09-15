#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

static NSString *EB143LogPath(void) {
    NSArray *paths = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
    NSString *dir = paths.firstObject ?: NSTemporaryDirectory();
    return [dir stringByAppendingPathComponent:@"eBayFixer.log"];
}

static void EB143Log(NSString *format, ...) {
    if (!format) return;
    va_list args;
    va_start(args, format);
    NSString *message = [[NSString alloc] initWithFormat:format arguments:args];
    va_end(args);
    if (!message.length) return;

    NSString *path = EB143LogPath();
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

static BOOL EB143IsHomeVLP(NSDictionary *root) {
    if (![root isKindOfClass:[NSDictionary class]]) return NO;
    NSDictionary *meta = [root[@"meta"] isKindOfClass:[NSDictionary class]] ? root[@"meta"] : nil;
    NSDictionary *pageTemplate = [meta[@"pageTemplate"] isKindOfClass:[NSDictionary class]] ? meta[@"pageTemplate"] : nil;
    return [[[pageTemplate objectForKey:@"templateId"] description] isEqualToString:@"VerticalLandingPage"] &&
           [[root objectForKey:@"modules"] isKindOfClass:[NSDictionary class]];
}

static BOOL EB143ModuleContainsTextBanner(NSDictionary *module) {
    if (![[module[@"_type"] description] isEqualToString:@"MadronaGenericModule"]) return NO;
    NSArray *cards = [module[@"cards"] isKindOfClass:[NSArray class]] ? module[@"cards"] : nil;
    for (id card in cards) {
        if (![card isKindOfClass:[NSDictionary class]]) continue;
        if ([[card[@"_type"] description] isEqualToString:@"TEXT_BANNER"]) return YES;
        NSArray *creatives = [card[@"creatives"] isKindOfClass:[NSArray class]] ? card[@"creatives"] : nil;
        for (id creative in creatives) {
            if (![creative isKindOfClass:[NSDictionary class]]) continue;
            if ([[creative[@"uxComponentName"] description] isEqualToString:@"TEXT_BANNER"]) return YES;
        }
    }
    return NO;
}

static NSDictionary *EB143IsolateTextBanner(NSDictionary *root) {
    NSDictionary *modules = [root[@"modules"] isKindOfClass:[NSDictionary class]] ? root[@"modules"] : nil;
    if (!modules.count) return root;

    NSString *selectedKey = nil;
    NSDictionary *selectedModule = nil;
    for (NSString *key in modules) {
        NSDictionary *module = [modules[key] isKindOfClass:[NSDictionary class]] ? modules[key] : nil;
        if (module && EB143ModuleContainsTextBanner(module)) {
            selectedKey = key;
            selectedModule = module;
            break;
        }
    }

    if (!selectedKey.length || !selectedModule) {
        EB143Log(@"HOME_ISO143 no_text_banner_candidate modules=%lu", (unsigned long)modules.count);
        return root;
    }

    NSMutableDictionary *out = [root mutableCopy];
    out[@"modules"] = @{ selectedKey : selectedModule };

    NSMutableDictionary *meta = [[root[@"meta"] isKindOfClass:[NSDictionary class]] ? root[@"meta"] : @{} mutableCopy];
    NSMutableDictionary *pageTemplate = [[meta[@"pageTemplate"] isKindOfClass:[NSDictionary class]] ? meta[@"pageTemplate"] : @{} mutableCopy];
    NSMutableDictionary *regions = [[pageTemplate[@"regions"] isKindOfClass:[NSDictionary class]] ? pageTemplate[@"regions"] : @{} mutableCopy];
    NSMutableDictionary *river = [[regions[@"RIVER"] isKindOfClass:[NSDictionary class]] ? regions[@"RIVER"] : @{} mutableCopy];
    NSMutableDictionary *layouts = [[river[@"layouts"] isKindOfClass:[NSDictionary class]] ? river[@"layouts"] : @{} mutableCopy];
    NSMutableDictionary *layout = [[layouts[@"LIST_1_COLUMN"] isKindOfClass:[NSDictionary class]] ? layouts[@"LIST_1_COLUMN"] : @{} mutableCopy];
    NSArray *positions = [layout[@"positions"] isKindOfClass:[NSArray class]] ? layout[@"positions"] : nil;

    NSMutableArray *kept = [NSMutableArray array];
    for (id position in positions) {
        if (![position isKindOfClass:[NSDictionary class]]) continue;
        if ([[position[@"moduleLocator"] description] isEqualToString:selectedKey]) [kept addObject:position];
    }

    if (!kept.count) {
        EB143Log(@"HOME_ISO143 candidate=%@ but_position_missing", selectedKey);
        return root;
    }

    layout[@"positions"] = kept;
    layouts[@"LIST_1_COLUMN"] = layout;
    river[@"layouts"] = layouts;
    regions[@"RIVER"] = river;
    pageTemplate[@"regions"] = regions;
    meta[@"pageTemplate"] = pageTemplate;
    out[@"meta"] = meta;

    EB143Log(@"HOME_ISO143 selected=%@ moduleType=%@ cardType=TEXT_BANNER positions=%lu modules_before=%lu modules_after=1",
             selectedKey,
             [selectedModule[@"_type"] description] ?: @"nil",
             (unsigned long)kept.count,
             (unsigned long)modules.count);
    return out;
}

%hook NSJSONSerialization

+ (id)JSONObjectWithData:(NSData *)data options:(NSJSONReadingOptions)opt error:(NSError **)error {
    id object = %orig;
    if (![object isKindOfClass:[NSDictionary class]] || !EB143IsHomeVLP((NSDictionary *)object)) return object;
    return EB143IsolateTextBanner((NSDictionary *)object);
}

%end

static UIViewController *EB143FindVLPIn(UIViewController *vc) {
    if (!vc) return nil;
    if ([NSStringFromClass([vc class]) containsString:@"HomeVerticalLandingPageViewController"]) return vc;
    if (vc.presentedViewController) {
        UIViewController *found = EB143FindVLPIn(vc.presentedViewController);
        if (found) return found;
    }
    if ([vc isKindOfClass:[UINavigationController class]]) {
        UIViewController *found = EB143FindVLPIn([(UINavigationController *)vc visibleViewController]);
        if (found) return found;
    }
    if ([vc isKindOfClass:[UITabBarController class]]) {
        UIViewController *found = EB143FindVLPIn([(UITabBarController *)vc selectedViewController]);
        if (found) return found;
    }
    for (UIViewController *child in vc.childViewControllers) {
        UIViewController *found = EB143FindVLPIn(child);
        if (found) return found;
    }
    return nil;
}

static UIViewController *EB143FindVLP(void) {
    for (UIWindow *window in [UIApplication sharedApplication].windows) {
        UIViewController *found = EB143FindVLPIn(window.rootViewController);
        if (found) return found;
    }
    return nil;
}

static void EB143Probe(NSString *phase) {
    UIViewController *vc = EB143FindVLP();
    if (!vc) {
        EB143Log(@"HOME_ISO143 probe=%@ controller=not_found", phase);
        return;
    }

    id sections = nil;
    @try { sections = [vc valueForKey:@"sectionModels"]; } @catch (__unused NSException *e) {}
    NSUInteger count = [sections respondsToSelector:@selector(count)] ? [sections count] : 0;
    EB143Log(@"HOME_ISO143 probe=%@ controller=%@ sectionModels=%@ count=%lu",
             phase, NSStringFromClass([vc class]), sections ? NSStringFromClass([sections class]) : @"nil", (unsigned long)count);
}

%ctor {
    if (![[[NSBundle mainBundle] bundleIdentifier] isEqualToString:@"com.ebay.iphone"]) return;
    %init;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ EB143Probe(@"3s"); });
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(5.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ EB143Probe(@"5s"); });
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(9.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ EB143Probe(@"9s"); });
}
