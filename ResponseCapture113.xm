#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <substrate.h>

static const void *EB113BodyKey = &EB113BodyKey;

static NSString *EB113LogPath(void) {
    NSArray *paths = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
    NSString *dir = paths.firstObject ?: NSTemporaryDirectory();
    return [dir stringByAppendingPathComponent:@"eBayFixer.log"];
}

static void EB113Log(NSString *format, ...) {
    if (!format) return;
    va_list args;
    va_start(args, format);
    NSString *message = [[NSString alloc] initWithFormat:format arguments:args];
    va_end(args);
    if (!message) return;

    NSString *line = [NSString stringWithFormat:@"%@ %@\n", [NSDate date], message];
    NSData *data = [line dataUsingEncoding:NSUTF8StringEncoding];
    NSString *path = EB113LogPath();
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

static NSString *EB113Kind(NSURL *url) {
    NSString *path = url.path.lowercaseString ?: @"";
    if ([path containsString:@"/experience/vertical_landing/v1/get_homepage"]) return @"HOME";
    if ([path containsString:@"/experience/vertical_landing/v1/module_provider"]) return @"HOME_PROVIDER";
    if ([path containsString:@"/experience/listing_details/v2/view_item"]) return @"ITEM";
    if ([path containsString:@"/experience/listing_details/v2/module_provider"] ||
        [path containsString:@"/experience/listing_details/v2/preview_draft_listing"] ||
        [path containsString:@"/experience/listing_details/v2/quick_view"]) return @"ITEM_PROVIDER";
    return nil;
}

static NSString *EB113ClassKey(Class cls) {
    return cls ? NSStringFromClass(cls) : @"";
}

static NSMutableDictionary *EB113DataOriginals(void) {
    static NSMutableDictionary *dict;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{ dict = [NSMutableDictionary dictionary]; });
    return dict;
}

static NSMutableDictionary *EB113CompleteOriginals(void) {
    static NSMutableDictionary *dict;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{ dict = [NSMutableDictionary dictionary]; });
    return dict;
}

static IMP EB113OriginalForObject(NSMutableDictionary *dict, id object) {
    Class cls = object_getClass(object);
    while (cls) {
        NSValue *value = dict[EB113ClassKey(cls)];
        if (value) return [value pointerValue];
        cls = class_getSuperclass(cls);
    }
    return NULL;
}

static NSString *EB113SanitizedPreview(NSData *data) {
    if (!data.length) return @"";
    NSUInteger max = MIN((NSUInteger)12000, data.length);
    NSData *slice = [data subdataWithRange:NSMakeRange(0, max)];
    NSString *text = [[NSString alloc] initWithData:slice encoding:NSUTF8StringEncoding];
    if (!text) return @"<non-UTF8 response>";

    text = [text stringByReplacingOccurrencesOfString:@"\n" withString:@" "];
    text = [text stringByReplacingOccurrencesOfString:@"\r" withString:@" "];
    return text;
}

static NSString *EB113JSONSummary(NSData *data) {
    if (!data.length) return @"none";
    NSError *error = nil;
    id json = [NSJSONSerialization JSONObjectWithData:data options:0 error:&error];
    if (!json) return [NSString stringWithFormat:@"not-json:%@/%ld", error.domain ?: @"none", (long)error.code];

    if ([json isKindOfClass:[NSDictionary class]]) {
        NSDictionary *dict = (NSDictionary *)json;
        NSArray *keys = [[dict allKeys] sortedArrayUsingComparator:^NSComparisonResult(id a, id b) {
            return [[a description] compare:[b description]];
        }];
        NSMutableArray *interesting = [NSMutableArray array];
        for (NSString *key in @[@"error", @"errors", @"message", @"status", @"code", @"modules", @"meta", @"warnings"]) {
            id value = dict[key];
            if (value) [interesting addObject:[NSString stringWithFormat:@"%@=%@", key, value]];
        }
        return [NSString stringWithFormat:@"keys=%@ interesting=%@", keys, interesting];
    }
    if ([json isKindOfClass:[NSArray class]]) {
        return [NSString stringWithFormat:@"array-count=%lu", (unsigned long)[(NSArray *)json count]];
    }
    return [NSString stringWithFormat:@"json-type=%@", NSStringFromClass([json class])];
}

static void EB113SaveResponse(NSString *kind, NSData *data) {
    if (!kind.length || !data.length) return;
    NSArray *paths = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
    NSString *dir = paths.firstObject ?: NSTemporaryDirectory();
    NSString *file = [NSString stringWithFormat:@"eBayFixer-%@-response.json", kind];
    [data writeToFile:[dir stringByAppendingPathComponent:file] atomically:YES];
}

typedef void (*EB113DidReceiveDataIMP)(id, SEL, NSURLSession *, NSURLSessionDataTask *, NSData *);
typedef void (*EB113DidCompleteIMP)(id, SEL, NSURLSession *, NSURLSessionTask *, NSError *);

static void EB113DidReceiveData(id self, SEL _cmd, NSURLSession *session, NSURLSessionDataTask *task, NSData *data) {
    NSString *kind = EB113Kind((task.currentRequest ?: task.originalRequest).URL);
    if (kind && data.length) {
        @synchronized (task) {
            NSMutableData *body = objc_getAssociatedObject(task, EB113BodyKey);
            if (!body) {
                body = [NSMutableData data];
                objc_setAssociatedObject(task, EB113BodyKey, body, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            }
            if (body.length < 256 * 1024) {
                NSUInteger remaining = (256 * 1024) - body.length;
                NSUInteger amount = MIN(remaining, data.length);
                [body appendData:[data subdataWithRange:NSMakeRange(0, amount)]];
            }
        }
    }

    EB113DidReceiveDataIMP original = (EB113DidReceiveDataIMP)EB113OriginalForObject(EB113DataOriginals(), self);
    if (original) original(self, _cmd, session, task, data);
}

static void EB113DidComplete(id self, SEL _cmd, NSURLSession *session, NSURLSessionTask *task, NSError *error) {
    NSString *kind = EB113Kind((task.currentRequest ?: task.originalRequest).URL);
    if (kind) {
        NSData *body = nil;
        @synchronized (task) {
            body = [objc_getAssociatedObject(task, EB113BodyKey) copy];
        }
        NSHTTPURLResponse *http = [task.response isKindOfClass:[NSHTTPURLResponse class]] ? (NSHTTPURLResponse *)task.response : nil;
        EB113Log(@"BODY %@ status=%ld bytes=%lu summary=%@", kind, (long)http.statusCode,
                 (unsigned long)body.length, EB113JSONSummary(body));
        EB113Log(@"BODY_PREVIEW %@ %@", kind, EB113SanitizedPreview(body));
        EB113SaveResponse(kind, body);
    }

    EB113DidCompleteIMP original = (EB113DidCompleteIMP)EB113OriginalForObject(EB113CompleteOriginals(), self);
    if (original) original(self, _cmd, session, task, error);
}

static BOOL EB113ClassImplementsDirectly(Class cls, SEL selector) {
    unsigned int count = 0;
    Method *methods = class_copyMethodList(cls, &count);
    BOOL found = NO;
    for (unsigned int i = 0; i < count; i++) {
        if (method_getName(methods[i]) == selector) {
            found = YES;
            break;
        }
    }
    if (methods) free(methods);
    return found;
}

static void EB113InstallDelegateHooks(void) {
    SEL dataSel = NSSelectorFromString(@"URLSession:dataTask:didReceiveData:");
    SEL completeSel = NSSelectorFromString(@"URLSession:task:didCompleteWithError:");

    int count = objc_getClassList(NULL, 0);
    if (count <= 0) return;
    Class *classes = (__unsafe_unretained Class *)calloc((size_t)count, sizeof(Class));
    count = objc_getClassList(classes, count);

    NSUInteger dataHooks = 0;
    NSUInteger completeHooks = 0;
    for (int i = 0; i < count; i++) {
        Class cls = classes[i];
        if (!cls) continue;
        NSString *key = EB113ClassKey(cls);

        if (!EB113DataOriginals()[key] && EB113ClassImplementsDirectly(cls, dataSel)) {
            IMP old = NULL;
            MSHookMessageEx(cls, dataSel, (IMP)EB113DidReceiveData, &old);
            if (old) {
                EB113DataOriginals()[key] = [NSValue valueWithPointer:old];
                dataHooks++;
            }
        }

        if (!EB113CompleteOriginals()[key] && EB113ClassImplementsDirectly(cls, completeSel)) {
            IMP old = NULL;
            MSHookMessageEx(cls, completeSel, (IMP)EB113DidComplete, &old);
            if (old) {
                EB113CompleteOriginals()[key] = [NSValue valueWithPointer:old];
                completeHooks++;
            }
        }
    }
    free(classes);

    if (dataHooks || completeHooks) {
        EB113Log(@"DELEGATE_HOOKS added data=%lu complete=%lu totals=%lu/%lu",
                 (unsigned long)dataHooks, (unsigned long)completeHooks,
                 (unsigned long)EB113DataOriginals().count,
                 (unsigned long)EB113CompleteOriginals().count);
    }
}

static void EB113Probe(NSString *className, NSArray *selectors) {
    Class cls = NSClassFromString(className);
    if (!cls) {
        EB113Log(@"PROBE class=%@ missing", className);
        return;
    }
    Class meta = object_getClass(cls);
    for (NSString *selectorName in selectors) {
        SEL sel = NSSelectorFromString(selectorName);
        Method instanceMethod = class_getInstanceMethod(cls, sel);
        Method classMethod = meta ? class_getInstanceMethod(meta, sel) : NULL;
        EB113Log(@"PROBE class=%@ sel=%@ instance=%d class=%d itype=%s ctype=%s",
                 className, selectorName, instanceMethod != NULL, classMethod != NULL,
                 instanceMethod ? method_getTypeEncoding(instanceMethod) : "-",
                 classMethod ? method_getTypeEncoding(classMethod) : "-");
    }
}

static void EB113RunProbes(void) {
    EB113Probe(@"_TtC14HomePageModule26ObjCHomePageFeatureToggles",
               @[@"vlpF90", @"vlpF90KillSwitch", @"preprodServiceVLPHomepage", @"preprodServiceVLPSegmentation"]);
    EB113Probe(@"_TtC14HomePageModule22HomePageFeatureToggles",
               @[@"vlpF90", @"vlpF90KillSwitch"]);
    EB113Probe(@"_TtC14HomePageModule30HomeVerticalLandingPageRequest",
               @[@"isF90User", @"baseURLString", @"supportedUxComponents"]);
    EB113Probe(@"_TtC14HomePageModule39HomeVerticalLandingPageSegmentationFlag",
               @[@"isF90UserValue"]);
    EB113Probe(@"_TtC14HomePageModule18HomeTabCoordinator",
               @[@"currentUseCase", @"setCurrentUseCase:", @"vlpFlowController", @"vlpViewController", @"homeViewController"]);
    EB113Probe(@"_TtC11ItemProduct29ObjCItemProductFeatureToggles",
               @[@"useViewItemExperienceServiceRaptorIOURL", @"useViewItemExperienceServiceRaptorIOPreviewURL"]);
    EB113Probe(@"_TtC11ItemProduct25ItemProductFeatureToggles",
               @[@"useViewItemExperienceServiceRaptorIOURL", @"useViewItemExperienceServiceRaptorIOPreviewURL"]);
}

%ctor {
    @autoreleasepool {
        if (![[[NSBundle mainBundle] bundleIdentifier] isEqualToString:@"com.ebay.iphone"]) return;
        for (NSNumber *delay in @[@0.5, @1.5, @3.0, @6.0, @10.0]) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay.doubleValue * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{
                EB113InstallDelegateHooks();
                EB113RunProbes();
            });
        }
    }
}
