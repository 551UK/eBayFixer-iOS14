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

static NSValue *EB113ValueForIMP(IMP imp) {
    if (!imp) return nil;
    return [NSValue value:&imp withObjCType:@encode(IMP)];
}

static IMP EB113IMPFromValue(NSValue *value) {
    if (!value) return NULL;
    IMP imp = NULL;
    [value getValue:&imp];
    return imp;
}

static IMP EB113OriginalForObject(NSMutableDictionary *dict, id object) {
    Class cls = object_getClass(object);
    while (cls) {
        NSValue *value = dict[EB113ClassKey(cls)];
        IMP imp = EB113IMPFromValue(value);
        if (imp) return imp;
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
        return [NSString stringWithFormat:@"keys=%@", keys];
    }
    if ([json isKindOfClass:[NSArray class]]) {
        return [NSString stringWithFormat:@"array-count=%lu", (unsigned long)[(NSArray *)json count]];
    }
    return [NSString stringWithFormat:@"json-type=%@", NSStringFromClass([json class])];
}

static NSString *EB113Documents(void) {
    NSArray *paths = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
    return paths.firstObject ?: NSTemporaryDirectory();
}

static void EB113SaveResponseNamed(NSString *name, NSData *data) {
    if (!name.length || !data.length) return;
    [data writeToFile:[EB113Documents() stringByAppendingPathComponent:name] atomically:YES];
}

static void EB113SaveResponse(NSString *kind, NSData *data) {
    if (!kind.length || !data.length) return;
    NSString *file = [NSString stringWithFormat:@"eBayFixer-%@-response.json", kind];
    EB113SaveResponseNamed(file, data);
}

static NSData *EB113AdaptHomeResponse(NSData *data, NSUInteger *adaptedModules) {
    if (adaptedModules) *adaptedModules = 0;
    if (!data.length) return data;

    NSError *error = nil;
    id object = [NSJSONSerialization JSONObjectWithData:data options:NSJSONReadingMutableContainers error:&error];
    if (![object isKindOfClass:[NSMutableDictionary class]]) return data;

    NSMutableDictionary *root = (NSMutableDictionary *)object;
    id modulesObject = root[@"modules"];
    if (![modulesObject isKindOfClass:[NSDictionary class]]) return data;

    NSMutableDictionary *modules = [modulesObject isKindOfClass:[NSMutableDictionary class]] ? modulesObject : [modulesObject mutableCopy];
    root[@"modules"] = modules;

    NSUInteger changed = 0;
    for (id key in [modules.allKeys copy]) {
        id rawModule = modules[key];
        if (![rawModule isKindOfClass:[NSDictionary class]]) continue;

        NSMutableDictionary *module = [rawModule isKindOfClass:[NSMutableDictionary class]] ? rawModule : [rawModule mutableCopy];
        NSString *type = [module[@"_type"] isKindOfClass:[NSString class]] ? module[@"_type"] : @"";
        if (![type isEqualToString:@"NavigationBarModule"]) continue;

        id containersObject = module[@"containers"];
        if (![containersObject isKindOfClass:[NSArray class]]) continue;
        NSArray *containers = (NSArray *)containersObject;
        if (containers.count == 0) continue;

        id first = containers.firstObject;
        if ([first isKindOfClass:[NSDictionary class]] && first[@"cardContainers"]) continue;

        // eBay 6.96's VLP NavigationBarModuleTransformer reads the legacy
        // key path "containers.0.cardContainers". Current VLP responses put
        // CardContainer objects directly in "containers". Wrap the modern
        // array in the legacy envelope before 6.96 sees the response.
        module[@"containers"] = @[@{ @"cardContainers": containers }];
        modules[key] = module;
        changed++;
    }

    if (changed == 0) return data;

    NSError *writeError = nil;
    NSData *adapted = [NSJSONSerialization dataWithJSONObject:root options:0 error:&writeError];
    if (!adapted.length || writeError) return data;
    if (adaptedModules) *adaptedModules = changed;
    return adapted;
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
            if (body.length < 512 * 1024) {
                NSUInteger remaining = (512 * 1024) - body.length;
                NSUInteger amount = MIN(remaining, data.length);
                [body appendData:[data subdataWithRange:NSMakeRange(0, amount)]];
            }
        }
    }

    // For Home only, hold the modern response until completion so it can be
    // converted to the 6.96 VLP schema before the real eBay delegate parses it.
    if ([kind isEqualToString:@"HOME"]) return;

    EB113DidReceiveDataIMP original = (EB113DidReceiveDataIMP)EB113OriginalForObject(EB113DataOriginals(), self);
    if (original) original(self, _cmd, session, task, data);
}

static void EB113DidComplete(id self, SEL _cmd, NSURLSession *session, NSURLSessionTask *task, NSError *error) {
    NSString *kind = EB113Kind((task.currentRequest ?: task.originalRequest).URL);
    NSData *body = nil;
    if (kind) {
        @synchronized (task) {
            body = [objc_getAssociatedObject(task, EB113BodyKey) copy];
        }
        NSHTTPURLResponse *http = [task.response isKindOfClass:[NSHTTPURLResponse class]] ? (NSHTTPURLResponse *)task.response : nil;
        EB113Log(@"BODY %@ status=%ld bytes=%lu summary=%@", kind, (long)http.statusCode,
                 (unsigned long)body.length, EB113JSONSummary(body));
        EB113SaveResponse(kind, body);
    }

    if ([kind isEqualToString:@"HOME"] && body.length) {
        NSUInteger adaptedModules = 0;
        NSData *adapted = EB113AdaptHomeResponse(body, &adaptedModules);
        EB113SaveResponseNamed(@"eBayFixer-HOME-adapted.json", adapted);
        EB113Log(@"HOME_ADAPT modules=%lu rawBytes=%lu adaptedBytes=%lu",
                 (unsigned long)adaptedModules,
                 (unsigned long)body.length,
                 (unsigned long)adapted.length);

        EB113DidReceiveDataIMP originalData = (EB113DidReceiveDataIMP)EB113OriginalForObject(EB113DataOriginals(), self);
        if (originalData) {
            SEL dataSel = NSSelectorFromString(@"URLSession:dataTask:didReceiveData:");
            originalData(self, dataSel, session, (NSURLSessionDataTask *)task, adapted);
        }
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
            NSValue *value = EB113ValueForIMP(old);
            if (value) {
                EB113DataOriginals()[key] = value;
                dataHooks++;
            }
        }

        if (!EB113CompleteOriginals()[key] && EB113ClassImplementsDirectly(cls, completeSel)) {
            IMP old = NULL;
            MSHookMessageEx(cls, completeSel, (IMP)EB113DidComplete, &old);
            NSValue *value = EB113ValueForIMP(old);
            if (value) {
                EB113CompleteOriginals()[key] = value;
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
    if (!cls) return;
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
    EB113Probe(@"_TtC14HomePageModule30HomeVerticalLandingPageRequest",
               @[@"isF90User", @"baseURLString", @"supportedUxComponents"]);
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
