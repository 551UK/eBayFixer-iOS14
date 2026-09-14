#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <substrate.h>

static NSMutableDictionary *EB119Originals(void) {
    static NSMutableDictionary *dict;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{ dict = [NSMutableDictionary dictionary]; });
    return dict;
}

static NSString *EB119LogPath(void) {
    NSArray *paths = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
    NSString *dir = paths.firstObject ?: NSTemporaryDirectory();
    return [dir stringByAppendingPathComponent:@"eBayFixer.log"];
}

static void EB119Log(NSString *format, ...) {
    if (!format) return;
    va_list args;
    va_start(args, format);
    NSString *message = [[NSString alloc] initWithFormat:format arguments:args];
    va_end(args);
    if (!message.length) return;

    NSString *line = [NSString stringWithFormat:@"%@ %@\n", [NSDate date], message];
    NSString *path = EB119LogPath();
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

static NSString *EB119Key(Class cls, SEL sel) {
    return [NSString stringWithFormat:@"%@::%@", NSStringFromClass(cls), NSStringFromSelector(sel)];
}

static NSValue *EB119ValueForIMP(IMP imp) {
    if (!imp) return nil;
    return [NSValue value:&imp withObjCType:@encode(IMP)];
}

static IMP EB119IMPFromValue(NSValue *value) {
    if (!value) return NULL;
    IMP imp = NULL;
    [value getValue:&imp];
    return imp;
}

static IMP EB119Original(id self, SEL sel) {
    Class cls = object_getClass(self);
    while (cls) {
        IMP imp = EB119IMPFromValue(EB119Originals()[EB119Key(cls, sel)]);
        if (imp) return imp;
        cls = class_getSuperclass(cls);
    }
    return NULL;
}

static void EB119ViewDidLoad(id self, SEL _cmd) {
    EB119Log(@"HOME_VC viewDidLoad class=%@", NSStringFromClass([self class]));
    void (*orig)(id, SEL) = (void (*)(id, SEL))EB119Original(self, _cmd);
    if (orig) orig(self, _cmd);
}

static void EB119ViewWillAppear(id self, SEL _cmd, BOOL animated) {
    EB119Log(@"HOME_VC viewWillAppear class=%@", NSStringFromClass([self class]));
    void (*orig)(id, SEL, BOOL) = (void (*)(id, SEL, BOOL))EB119Original(self, _cmd);
    if (orig) orig(self, _cmd, animated);
}

static void EB119ViewDidAppear(id self, SEL _cmd, BOOL animated) {
    EB119Log(@"HOME_VC viewDidAppear class=%@", NSStringFromClass([self class]));
    void (*orig)(id, SEL, BOOL) = (void (*)(id, SEL, BOOL))EB119Original(self, _cmd);
    if (orig) orig(self, _cmd, animated);
}

static void EB119HookSelector(Class cls, SEL sel, IMP replacement) {
    if (!cls || !sel || !replacement) return;
    NSString *key = EB119Key(cls, sel);
    if (EB119Originals()[key]) return;
    Method method = class_getInstanceMethod(cls, sel);
    if (!method) return;
    IMP old = NULL;
    MSHookMessageEx(cls, sel, replacement, &old);
    NSValue *value = EB119ValueForIMP(old);
    if (value) EB119Originals()[key] = value;
}

static void EB119ProbeClass(NSString *name) {
    Class cls = NSClassFromString(name);
    if (!cls) return;
    Class superCls = class_getSuperclass(cls);

    NSMutableArray *interesting = [NSMutableArray array];
    unsigned int count = 0;
    Method *methods = class_copyMethodList(cls, &count);
    for (unsigned int i = 0; i < count; i++) {
        NSString *methodName = NSStringFromSelector(method_getName(methods[i]));
        NSString *lower = methodName.lowercaseString;
        if ([lower containsString:@"view"] || [lower containsString:@"home"] ||
            [lower containsString:@"vlp"] || [lower containsString:@"usecase"] ||
            [lower containsString:@"refresh"] || [lower containsString:@"load"]) {
            [interesting addObject:methodName];
        }
    }
    if (methods) free(methods);

    EB119Log(@"HOME_FLOW_PROBE class=%@ super=%@ size=%zu methods=%@",
             name, superCls ? NSStringFromClass(superCls) : @"nil",
             class_getInstanceSize(cls), interesting);
}

static void EB119Install(void) {
    NSArray *classes = @[
        @"_TtC14HomePageModule37HomeVerticalLandingPageViewController",
        @"_TtC14HomePageModule33VerticalLandingPageViewController",
        @"_TtC14HomePageModule25HomeContentViewController",
        @"_TtC14HomePageModule18HomeViewController"
    ];

    static NSMutableSet *probed;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{ probed = [NSMutableSet set]; });

    for (NSString *name in classes) {
        Class cls = NSClassFromString(name);
        if (!cls) continue;
        if (![probed containsObject:name]) {
            [probed addObject:name];
            EB119ProbeClass(name);
        }
        EB119HookSelector(cls, @selector(viewDidLoad), (IMP)EB119ViewDidLoad);
        EB119HookSelector(cls, @selector(viewWillAppear:), (IMP)EB119ViewWillAppear);
        EB119HookSelector(cls, @selector(viewDidAppear:), (IMP)EB119ViewDidAppear);
    }

    if (![probed containsObject:@"HomeTabCoordinator"]) {
        Class coordinator = NSClassFromString(@"_TtC14HomePageModule18HomeTabCoordinator");
        if (coordinator) {
            [probed addObject:@"HomeTabCoordinator"];
            EB119ProbeClass(@"_TtC14HomePageModule18HomeTabCoordinator");
        }
    }
}

static void EB119ScheduleInstall(void) {
    for (NSNumber *delay in @[@0.1, @0.5, @1.0, @2.0, @4.0, @8.0]) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay.doubleValue * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{ EB119Install(); });
    }
}
