#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>

static NSString *EB146LogPath(void) {
    NSArray *paths = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
    NSString *dir = paths.firstObject ?: NSTemporaryDirectory();
    return [dir stringByAppendingPathComponent:@"eBayFixer.log"];
}

static void EB146Log(NSString *format, ...) {
    if (!format) return;
    va_list args;
    va_start(args, format);
    NSString *message = [[NSString alloc] initWithFormat:format arguments:args];
    va_end(args);
    if (!message.length) return;

    NSString *path = EB146LogPath();
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
    } @catch (__unused NSException *e) {}
}

static UIViewController *EB146FindVLPIn(UIViewController *vc) {
    if (!vc) return nil;
    if ([NSStringFromClass([vc class]) containsString:@"HomeVerticalLandingPageViewController"]) return vc;
    if (vc.presentedViewController) {
        UIViewController *found = EB146FindVLPIn(vc.presentedViewController);
        if (found) return found;
    }
    if ([vc isKindOfClass:[UINavigationController class]]) {
        UIViewController *found = EB146FindVLPIn([(UINavigationController *)vc visibleViewController]);
        if (found) return found;
    }
    if ([vc isKindOfClass:[UITabBarController class]]) {
        UIViewController *found = EB146FindVLPIn([(UITabBarController *)vc selectedViewController]);
        if (found) return found;
    }
    for (UIViewController *child in vc.childViewControllers) {
        UIViewController *found = EB146FindVLPIn(child);
        if (found) return found;
    }
    return nil;
}

static UIViewController *EB146FindVLP(void) {
    for (UIWindow *window in [UIApplication sharedApplication].windows) {
        UIViewController *found = EB146FindVLPIn(window.rootViewController);
        if (found) return found;
    }
    return nil;
}

static BOOL EB146InterestingName(NSString *name) {
    NSString *lower = name.lowercaseString;
    return [lower containsString:@"model"] ||
           [lower containsString:@"section"] ||
           [lower containsString:@"manager"] ||
           [lower containsString:@"load"] ||
           [lower containsString:@"fetch"] ||
           [lower containsString:@"refresh"] ||
           [lower containsString:@"error"] ||
           [lower containsString:@"subject"] ||
           [lower containsString:@"publisher"] ||
           [lower containsString:@"cancel"];
}

static void EB146DumpClass(Class cls) {
    if (!cls) return;
    EB146Log(@"HOME_META146 class=%@ size=%zu super=%@",
             NSStringFromClass(cls), class_getInstanceSize(cls),
             class_getSuperclass(cls) ? NSStringFromClass(class_getSuperclass(cls)) : @"nil");

    unsigned int ivarCount = 0;
    Ivar *ivars = class_copyIvarList(cls, &ivarCount);
    EB146Log(@"HOME_META146 ivar_count class=%@ count=%u", NSStringFromClass(cls), ivarCount);
    for (unsigned int i = 0; i < ivarCount; i++) {
        const char *name = ivar_getName(ivars[i]);
        const char *type = ivar_getTypeEncoding(ivars[i]);
        ptrdiff_t off = ivar_getOffset(ivars[i]);
        EB146Log(@"HOME_META146 ivar class=%@ name=%s type=%s offset=0x%tx",
                 NSStringFromClass(cls), name ?: "?", type ?: "?", off);
    }
    if (ivars) free(ivars);

    unsigned int methodCount = 0;
    Method *methods = class_copyMethodList(cls, &methodCount);
    for (unsigned int i = 0; i < methodCount; i++) {
        NSString *name = NSStringFromSelector(method_getName(methods[i]));
        if (EB146InterestingName(name)) {
            EB146Log(@"HOME_META146 method class=%@ name=%@ types=%s",
                     NSStringFromClass(cls), name, method_getTypeEncoding(methods[i]) ?: "?");
        }
    }
    if (methods) free(methods);

    unsigned int propCount = 0;
    objc_property_t *props = class_copyPropertyList(cls, &propCount);
    for (unsigned int i = 0; i < propCount; i++) {
        const char *name = property_getName(props[i]);
        const char *attrs = property_getAttributes(props[i]);
        NSString *n = name ? [NSString stringWithUTF8String:name] : @"?";
        if (EB146InterestingName(n)) {
            EB146Log(@"HOME_META146 property class=%@ name=%@ attrs=%s",
                     NSStringFromClass(cls), n, attrs ?: "?");
        }
    }
    if (props) free(props);
}

static void EB146Probe(NSString *phase) {
    UIViewController *vc = EB146FindVLP();
    if (!vc) {
        EB146Log(@"HOME_META146 phase=%@ controller=not_found", phase);
        return;
    }

    id sections = nil;
    @try { sections = [vc valueForKey:@"sectionModels"]; } @catch (__unused NSException *e) {}
    NSUInteger count = [sections respondsToSelector:@selector(count)] ? [sections count] : 0;
    EB146Log(@"HOME_META146 phase=%@ controller=%@ sectionModels=%@ count=%lu",
             phase, NSStringFromClass([vc class]),
             sections ? NSStringFromClass([sections class]) : @"nil",
             (unsigned long)count);

    for (Class cls = [vc class]; cls && cls != [UIViewController class]; cls = class_getSuperclass(cls)) {
        EB146DumpClass(cls);
    }
}

%ctor {
    if (![[[NSBundle mainBundle] bundleIdentifier] isEqualToString:@"com.ebay.iphone"]) return;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        EB146Probe(@"2.5s");
    });
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(7.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        UIViewController *vc = EB146FindVLP();
        id sections = nil;
        if (vc) { @try { sections = [vc valueForKey:@"sectionModels"]; } @catch (__unused NSException *e) {} }
        NSUInteger count = [sections respondsToSelector:@selector(count)] ? [sections count] : 0;
        EB146Log(@"HOME_META146 phase=7s controller=%@ sectionModels=%@ count=%lu",
                 vc ? NSStringFromClass([vc class]) : @"not_found",
                 sections ? NSStringFromClass([sections class]) : @"nil",
                 (unsigned long)count);
    });
}
