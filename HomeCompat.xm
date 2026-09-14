#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <substrate.h>

static void EB119ScheduleInstall(void);

static NSMutableSet *EBHomeInstalledHooks(void) {
    static NSMutableSet *set;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{ set = [NSMutableSet set]; });
    return set;
}

static BOOL EBHomeYes(id self, SEL _cmd) { return YES; }
static BOOL EBHomeNo(id self, SEL _cmd) { return NO; }

static BOOL EBHomeHook(Class cls, NSString *selectorName, IMP replacement) {
    if (!cls || !selectorName.length || !replacement) return NO;
    SEL selector = NSSelectorFromString(selectorName);
    if (!class_getInstanceMethod(cls, selector)) return NO;

    NSString *key = [NSString stringWithFormat:@"%@::%@", NSStringFromClass(cls), selectorName];
    @synchronized (EBHomeInstalledHooks()) {
        if ([EBHomeInstalledHooks() containsObject:key]) return YES;
        MSHookMessageEx(cls, selector, replacement, NULL);
        [EBHomeInstalledHooks() addObject:key];
    }
    return YES;
}

static NSString *EB122LogPath(void) {
    NSArray *paths = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
    NSString *dir = paths.firstObject ?: NSTemporaryDirectory();
    return [dir stringByAppendingPathComponent:@"eBayFixer.log"];
}

static void EB122Log(NSString *format, ...) {
    if (!format) return;
    va_list args;
    va_start(args, format);
    NSString *message = [[NSString alloc] initWithFormat:format arguments:args];
    va_end(args);
    if (!message.length) return;

    NSString *line = [NSString stringWithFormat:@"%@ %@\n", [NSDate date], message];
    NSString *path = EB122LogPath();
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

static BOOL EB122SetBoolIvar(id object, const char *name, BOOL value) {
    if (!object || !name) return NO;
    Ivar ivar = class_getInstanceVariable([object class], name);
    if (!ivar) return NO;

    const char *type = ivar_getTypeEncoding(ivar);
    if (!type || (type[0] != 'B' && type[0] != 'c')) return NO;

    ptrdiff_t offset = ivar_getOffset(ivar);
    uint8_t *storage = ((uint8_t *)(__bridge void *)object) + offset;
    BOOL before = (*storage != 0);
    *storage = value ? 1 : 0;
    EB122Log(@"HOME_TOGGLE_IVAR class=%@ name=%s offset=%td before=%d after=%d type=%s",
             NSStringFromClass([object class]), name, offset, before, value, type);
    return YES;
}

static id (*EB122OrigToggleInit)(id, SEL) = NULL;
static BOOL EB122ToggleInitHooked = NO;

static id EB122ToggleInit(id self, SEL _cmd) {
    id result = EB122OrigToggleInit ? EB122OrigToggleInit(self, _cmd) : self;
    BOOL f90 = EB122SetBoolIvar(result, "_vlpF90", YES);
    BOOL kill = EB122SetBoolIvar(result, "_vlpF90KillSwitch", NO);
    EB122Log(@"HOME_TOGGLE_SNAPSHOT init class=%@ f90=%d killSwitch=%d",
             result ? NSStringFromClass([result class]) : @"nil", f90, kill);
    return result;
}

static void EB122InstallToggleSnapshotHook(void) {
    if (EB122ToggleInitHooked) return;
    Class cls = NSClassFromString(@"_TtC14HomePageModule26ObjCHomePageFeatureToggles");
    if (!cls) return;

    Method method = class_getInstanceMethod(cls, @selector(init));
    if (!method) {
        EB122Log(@"HOME_TOGGLE_SNAPSHOT class found but init missing");
        return;
    }

    MSHookMessageEx(cls, @selector(init), (IMP)EB122ToggleInit, (IMP *)&EB122OrigToggleInit);
    EB122ToggleInitHooked = YES;
    EB122Log(@"HOME_TOGGLE_SNAPSHOT init hook installed class=%@ size=%zu",
             NSStringFromClass(cls), class_getInstanceSize(cls));
}

static void EBInstallHomeCompat(void) {
    NSArray *toggleClasses = @[
        @"_TtC14HomePageModule26ObjCHomePageFeatureToggles",
        @"ObjCHomePageFeatureToggles",
        @"_TtC14HomePageModule22HomePageFeatureToggles",
        @"HomePageFeatureToggles"
    ];

    for (NSString *name in toggleClasses) {
        Class cls = NSClassFromString(name);
        EBHomeHook(cls, @"vlpF90", (IMP)EBHomeYes);
        EBHomeHook(cls, @"vlpF90KillSwitch", (IMP)EBHomeNo);
        EBHomeHook(cls, @"preprodServiceVLPHomepage", (IMP)EBHomeNo);
        EBHomeHook(cls, @"preprodServiceVLPSegmentation", (IMP)EBHomeNo);
    }

    EB122InstallToggleSnapshotHook();
}

%ctor {
    @autoreleasepool {
        if (![[[NSBundle mainBundle] bundleIdentifier] isEqualToString:@"com.ebay.iphone"]) return;
        EBInstallHomeCompat();
        EB119ScheduleInstall();
        for (NSNumber *delay in @[@0.01, @0.1, @0.25, @0.75, @1.5, @3.0, @5.0, @8.0]) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay.doubleValue * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{ EBInstallHomeCompat(); });
        }
    }
}

#include "HomeFlowProbe119.xm"
