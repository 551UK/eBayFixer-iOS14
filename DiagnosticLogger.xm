#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <mach-o/dyld.h>
#import <fcntl.h>
#import <unistd.h>
#import <string.h>
#import "Prefs.h"

static NSString *const EBDiagBundleID = @"com.ebay.iphone";
static NSString *const EBDiagVersion = @"1.0.53";

static NSArray<NSString *> *EBDiagPaths(void) {
    static NSArray<NSString *> *paths;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        NSMutableArray<NSString *> *out = [NSMutableArray array];

        // Convenient rootful-jailbreak locations. These may be sandbox-blocked
        // on some setups, so the app-container Documents path is always kept
        // as a guaranteed fallback.
        [out addObject:@"/var/mobile/Library/Logs/eBayFixerDiagnostic.log"];
        [out addObject:@"/var/mobile/Documents/eBayFixerDiagnostic.log"];

        NSString *home = NSHomeDirectory();
        if (home.length) {
            NSString *container = [home stringByAppendingPathComponent:@"Documents/eBayFixerDiagnostic.log"];
            if (![out containsObject:container]) [out addObject:container];
        }
        paths = [out copy];
    });
    return paths;
}

static void EBDiagWriteRaw(NSString *text, BOOL truncateFirst) {
    if (![text isKindOfClass:[NSString class]] || text.length == 0) return;
    NSData *data = [text dataUsingEncoding:NSUTF8StringEncoding];
    if (!data.length) return;

    for (NSString *path in EBDiagPaths()) {
        const char *fsPath = path.fileSystemRepresentation;
        if (!fsPath) continue;
        int flags = O_WRONLY | O_CREAT | (truncateFirst ? O_TRUNC : O_APPEND);
        int fd = open(fsPath, flags, 0644);
        if (fd < 0) continue;
        const uint8_t *bytes = data.bytes;
        size_t remaining = data.length;
        while (remaining > 0) {
            ssize_t n = write(fd, bytes, remaining);
            if (n <= 0) break;
            bytes += n;
            remaining -= (size_t)n;
        }
        close(fd);
    }
}

static void EBDiagLog(NSString *format, ...) NS_FORMAT_FUNCTION(1,2);
static void EBDiagLog(NSString *format, ...) {
    if (!format.length) return;
    va_list args;
    va_start(args, format);
    NSString *body = [[NSString alloc] initWithFormat:format arguments:args];
    va_end(args);

    NSTimeInterval uptime = [NSProcessInfo processInfo].systemUptime;
    NSString *line = [NSString stringWithFormat:@"[%0.3f] %@\n", uptime, body ?: @""];
    EBDiagWriteRaw(line, NO);
    NSLog(@"[eBayFixerDiag] %@", body ?: @"");
}

static BOOL EBDiagImageLoaded(const char *needle) {
    if (!needle) return NO;
    uint32_t count = _dyld_image_count();
    for (uint32_t i = 0; i < count; i++) {
        const char *name = _dyld_get_image_name(i);
        if (name && strstr(name, needle)) return YES;
    }
    return NO;
}

static NSString *EBDiagVisibleControllerName(void) {
    UIApplication *app = [UIApplication sharedApplication];
    UIWindow *window = app.keyWindow;
    if (!window) {
        for (UIWindow *candidate in app.windows) {
            if (!candidate.hidden && candidate.alpha > 0.0) {
                window = candidate;
                break;
            }
        }
    }

    UIViewController *vc = window.rootViewController;
    if (!vc) return @"<none>";

    for (NSInteger depth = 0; depth < 12; depth++) {
        UIViewController *next = nil;
        if (vc.presentedViewController) {
            next = vc.presentedViewController;
        } else if ([vc isKindOfClass:[UINavigationController class]]) {
            next = ((UINavigationController *)vc).visibleViewController;
        } else if ([vc isKindOfClass:[UITabBarController class]]) {
            next = ((UITabBarController *)vc).selectedViewController;
        }
        if (!next || next == vc) break;
        vc = next;
    }
    return NSStringFromClass([vc class]) ?: @"<unknown>";
}

static NSString *EBDiagClassFlag(const char *name) {
    return objc_lookUpClass(name) ? @"Y" : @"N";
}

static void EBDiagSnapshot(NSString *reason) {
    UIApplicationState state = [UIApplication sharedApplication].applicationState;
    EBDiagLog(@"SNAPSHOT %@ state=%ld visible=%@ images{Home=%@ Selling=%@ Foundations=%@ Item=%@} classes{HomeVLP=%@ HomeContent=%@ HomeToggles=%@ ItemToggles=%@}",
              reason ?: @"",
              (long)state,
              EBDiagVisibleControllerName(),
              EBDiagImageLoaded("HomePageModule.framework") ? @"Y" : @"N",
              EBDiagImageLoaded("SellingModule.framework") ? @"Y" : @"N",
              EBDiagImageLoaded("FoundationsAppFeatures.framework") ? @"Y" : @"N",
              EBDiagImageLoaded("ItemProduct.framework") ? @"Y" : @"N",
              EBDiagClassFlag("_TtC14HomePageModule37HomeVerticalLandingPageViewController"),
              EBDiagClassFlag("_TtC14HomePageModule25HomeContentViewController"),
              EBDiagClassFlag("_TtC14HomePageModule26ObjCHomePageFeatureToggles"),
              EBDiagClassFlag("_TtC11ItemProduct29ObjCItemProductFeatureToggles"));
}

static void EBDiagInstallObservers(void) {
    NSNotificationCenter *nc = [NSNotificationCenter defaultCenter];
    NSArray<NSString *> *names = @[
        UIApplicationDidFinishLaunchingNotification,
        UIApplicationDidBecomeActiveNotification,
        UIApplicationWillEnterForegroundNotification,
        UIApplicationDidEnterBackgroundNotification,
        UIWindowDidBecomeVisibleNotification,
        UIWindowDidBecomeKeyNotification
    ];

    for (NSString *name in names) {
        [nc addObserverForName:name object:nil queue:[NSOperationQueue mainQueue] usingBlock:^(NSNotification *note) {
            EBDiagLog(@"NOTIFY %@", note.name);
            EBDiagSnapshot(note.name);
        }];
    }
}

static void EBDiagStart(void) {
    NSString *header = [NSString stringWithFormat:
        @"===== eBayFixer diagnostic %@ =====\n"
         "date=%@\n"
         "device=%@\n"
         "system=%@ %@\n"
         "app=%@ build=%@\n"
         "home=%@\n"
         "paths=%@\n",
         EBDiagVersion,
         [NSDate date],
         [UIDevice currentDevice].model ?: @"?",
         [UIDevice currentDevice].systemName ?: @"?",
         [UIDevice currentDevice].systemVersion ?: @"?",
         [[NSBundle mainBundle] objectForInfoDictionaryKey:@"CFBundleShortVersionString"] ?: @"?",
         [[NSBundle mainBundle] objectForInfoDictionaryKey:@"CFBundleVersion"] ?: @"?",
         NSHomeDirectory() ?: @"?",
         [EBDiagPaths() componentsJoinedByString:@", "]];

    EBDiagWriteRaw(header, YES);
    EBDiagLog(@"LOGGER_START main=%d prefs=%d", [NSThread isMainThread] ? 1 : 0, EBPrefsEnabled() ? 1 : 0);
    EBDiagInstallObservers();
    EBDiagSnapshot(@"start");

    NSArray<NSNumber *> *delays = @[
        @0.00, @0.02, @0.05, @0.10, @0.15, @0.25, @0.40, @0.60,
        @0.90, @1.20, @1.60, @2.00, @2.50, @3.00, @4.00, @5.00,
        @7.00, @10.00
    ];
    for (NSNumber *delay in delays) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay.doubleValue * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            EBDiagSnapshot([NSString stringWithFormat:@"timer+%.2fs", delay.doubleValue]);
        });
    }
}

%ctor {
    @autoreleasepool {
        if (![[[NSBundle mainBundle] bundleIdentifier] isEqualToString:EBDiagBundleID] || !EBPrefsEnabled()) return;

        // Deliberately do not inspect Swift/ObjC classes or UIKit here. The
        // logger itself starts only after dyld has returned control to the
        // main queue, so it does not recreate the startup problem being tested.
        dispatch_async(dispatch_get_main_queue(), ^{
            EBDiagStart();
        });
    }
}
