#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <substrate.h>

static BOOL (*EB118OrigStateGetter)(id, SEL) = NULL;
static void (*EB118OrigStateSetter)(id, SEL, BOOL) = NULL;

static NSString *EB118LogPath(void) {
    NSArray *paths = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
    NSString *dir = paths.firstObject ?: NSTemporaryDirectory();
    return [dir stringByAppendingPathComponent:@"eBayFixer.log"];
}

static void EB118Log(NSString *format, ...) {
    if (!format) return;
    va_list args;
    va_start(args, format);
    NSString *message = [[NSString alloc] initWithFormat:format arguments:args];
    va_end(args);
    if (!message.length) return;

    NSString *line = [NSString stringWithFormat:@"%@ %@\n", [NSDate date], message];
    NSString *path = EB118LogPath();
    if (![[NSFileManager defaultManager] fileExistsAtPath:path]) {
        [[NSFileManager defaultManager] createFileAtPath:path contents:nil attributes:nil];
    }
    NSFileHandle *handle = [NSFileHandle fileHandleForWritingAtPath:path];
    if (!handle) return;
    @try {
        [handle seekToEndOfFile];
        [handle writeData:[line dataUsingEncoding:NSUTF8StringEncoding]];
        [handle closeFile];
    } @catch (__unused NSException *exception) {}
}

static BOOL EB118StateGetter(id self, SEL _cmd) {
    return YES;
}

static void EB118StateSetter(id self, SEL _cmd, BOOL enabled) {
    if (EB118OrigStateSetter) EB118OrigStateSetter(self, _cmd, YES);
}

static void EB118ProbeClass(Class cls) {
    if (!cls) return;
    NSMutableArray *methodNames = [NSMutableArray array];
    unsigned int methodCount = 0;
    Method *methods = class_copyMethodList(cls, &methodCount);
    for (unsigned int i = 0; i < methodCount; i++) {
        NSString *name = NSStringFromSelector(method_getName(methods[i]));
        NSString *lower = name.lowercaseString;
        if ([lower containsString:@"vlp"] || [lower containsString:@"home"] || [lower containsString:@"enabled"]) {
            [methodNames addObject:[NSString stringWithFormat:@"%@:%s", name, method_getTypeEncoding(methods[i]) ?: "-"]];
        }
    }
    if (methods) free(methods);

    NSMutableArray *ivarNames = [NSMutableArray array];
    unsigned int ivarCount = 0;
    Ivar *ivars = class_copyIvarList(cls, &ivarCount);
    for (unsigned int i = 0; i < ivarCount; i++) {
        const char *rawName = ivar_getName(ivars[i]);
        const char *rawType = ivar_getTypeEncoding(ivars[i]);
        NSString *name = rawName ? [NSString stringWithUTF8String:rawName] : @"";
        NSString *lower = name.lowercaseString;
        if ([lower containsString:@"vlp"] || [lower containsString:@"home"] || [lower containsString:@"enabled"]) {
            [ivarNames addObject:[NSString stringWithFormat:@"%@:%s@%td", name, rawType ?: "-", ivar_getOffset(ivars[i])]];
        }
    }
    if (ivars) free(ivars);

    EB118Log(@"HOME_STATE_PROBE class=%@ methods=%@ ivars=%@", NSStringFromClass(cls), methodNames, ivarNames);
}

static void EB118Install(void) {
    static BOOL installed = NO;

    Class state = NSClassFromString(@"_TtC14HomePageModule28HomeVerticalLandingPageState");
    Class flow = NSClassFromString(@"_TtC14HomePageModule37HomeVerticalLandingPageFlowController");
    Class factory = NSClassFromString(@"_TtC14HomePageModule44HomeVerticalLandingPageFlowControllerFactory");

    static dispatch_once_t probeOnce;
    if (state || flow || factory) {
        dispatch_once(&probeOnce, ^{
            EB118ProbeClass(state);
            EB118ProbeClass(flow);
            EB118ProbeClass(factory);
        });
    }

    if (installed || !state) return;

    SEL getter = NSSelectorFromString(@"isHomeVLPEnabled");
    Method getterMethod = class_getInstanceMethod(state, getter);
    if (getterMethod) {
        const char *types = method_getTypeEncoding(getterMethod);
        if (types && (types[0] == 'B' || types[0] == 'c')) {
            MSHookMessageEx(state, getter, (IMP)EB118StateGetter, (IMP *)&EB118OrigStateGetter);
            EB118Log(@"HOME_STATE_FORCE getter=isHomeVLPEnabled installed=1");
            installed = YES;
        }
    }

    SEL setter = NSSelectorFromString(@"setIsHomeVLPEnabled:");
    Method setterMethod = class_getInstanceMethod(state, setter);
    if (setterMethod) {
        MSHookMessageEx(state, setter, (IMP)EB118StateSetter, (IMP *)&EB118OrigStateSetter);
        EB118Log(@"HOME_STATE_FORCE setter=setIsHomeVLPEnabled: installed=1");
        installed = YES;
    }

    if (!installed) {
        EB118Log(@"HOME_STATE_FORCE no ObjC-accessible isHomeVLPEnabled accessor");
    }
}

%ctor {
    @autoreleasepool {
        if (![[[NSBundle mainBundle] bundleIdentifier] isEqualToString:@"com.ebay.iphone"]) return;
        for (NSNumber *delay in @[@0.1, @0.5, @1.0, @2.0, @4.0, @8.0]) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay.doubleValue * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{ EB118Install(); });
        }
    }
}
