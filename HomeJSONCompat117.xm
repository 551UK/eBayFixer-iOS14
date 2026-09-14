#import <Foundation/Foundation.h>

static NSString *EB117LogPath(void) {
    NSArray *paths = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
    NSString *dir = paths.firstObject ?: NSTemporaryDirectory();
    return [dir stringByAppendingPathComponent:@"eBayFixer.log"];
}

static void EB117Log(NSString *line) {
    if (!line.length) return;
    NSString *path = EB117LogPath();
    if (![[NSFileManager defaultManager] fileExistsAtPath:path]) {
        [[NSFileManager defaultManager] createFileAtPath:path contents:nil attributes:nil];
    }
    NSFileHandle *handle = [NSFileHandle fileHandleForWritingAtPath:path];
    if (!handle) return;
    NSString *full = [NSString stringWithFormat:@"%@ %@\n", [NSDate date], line];
    @try {
        [handle seekToEndOfFile];
        [handle writeData:[full dataUsingEncoding:NSUTF8StringEncoding]];
        [handle closeFile];
    } @catch (__unused NSException *exception) {}
}

static BOOL EB117IsHomeVLP(NSDictionary *root) {
    if (![root isKindOfClass:[NSDictionary class]]) return NO;
    NSDictionary *meta = [root[@"meta"] isKindOfClass:[NSDictionary class]] ? root[@"meta"] : nil;
    NSDictionary *pageTemplate = [meta[@"pageTemplate"] isKindOfClass:[NSDictionary class]] ? meta[@"pageTemplate"] : nil;
    if (![[pageTemplate[@"templateId"] description] isEqualToString:@"VerticalLandingPage"]) return NO;

    NSArray *tracking = [meta[@"trackingList"] isKindOfClass:[NSArray class]] ? meta[@"trackingList"] : nil;
    for (id entry in tracking) {
        if (![entry isKindOfClass:[NSDictionary class]]) continue;
        NSDictionary *props = [entry[@"eventProperty"] isKindOfClass:[NSDictionary class]] ? entry[@"eventProperty"] : nil;
        if ([[props[@"vlpname"] description] isEqualToString:@"vlp_homepage"]) return YES;
    }

    NSDictionary *modules = [root[@"modules"] isKindOfClass:[NSDictionary class]] ? root[@"modules"] : nil;
    for (id module in modules.allValues) {
        if (![module isKindOfClass:[NSDictionary class]]) continue;
        NSDictionary *moduleMeta = [module[@"meta"] isKindOfClass:[NSDictionary class]] ? module[@"meta"] : nil;
        NSArray *moduleTracking = [moduleMeta[@"trackingList"] isKindOfClass:[NSArray class]] ? moduleMeta[@"trackingList"] : nil;
        for (id entry in moduleTracking) {
            if (![entry isKindOfClass:[NSDictionary class]]) continue;
            NSDictionary *props = [entry[@"eventProperty"] isKindOfClass:[NSDictionary class]] ? entry[@"eventProperty"] : nil;
            if ([[props[@"vlpname"] description] isEqualToString:@"vlp_homepage"]) return YES;
        }
    }
    return NO;
}

static BOOL EB117UnsupportedType(NSString *type) {
    return [type isEqualToString:@"SliderControls"] ||
           [type isEqualToString:@"CarouselControls"] ||
           [type isEqualToString:@"EekIcon"];
}

static id EB117Sanitize(id value, NSUInteger *removed) {
    if ([value isKindOfClass:[NSDictionary class]]) {
        NSDictionary *source = (NSDictionary *)value;
        NSString *type = [source[@"_type"] isKindOfClass:[NSString class]] ? source[@"_type"] : nil;
        if (type.length && EB117UnsupportedType(type)) {
            if (removed) (*removed)++;
            return nil;
        }

        NSMutableDictionary *out = [NSMutableDictionary dictionaryWithCapacity:source.count];
        for (id key in source) {
            if ([key isKindOfClass:[NSString class]] && [(NSString *)key isEqualToString:@"__homepage"]) {
                if (removed) (*removed)++;
                continue;
            }
            id child = EB117Sanitize(source[key], removed);
            if (child) out[key] = child;
        }
        if ([out[@"controls"] isKindOfClass:[NSDictionary class]] && [(NSDictionary *)out[@"controls"] count] == 0) {
            [out removeObjectForKey:@"controls"];
        }
        return out;
    }

    if ([value isKindOfClass:[NSArray class]]) {
        NSMutableArray *out = [NSMutableArray array];
        for (id childValue in (NSArray *)value) {
            id child = EB117Sanitize(childValue, removed);
            if (child) [out addObject:child];
        }
        return out;
    }

    return value;
}

static NSDictionary *EB117AdaptHome(NSDictionary *root, NSUInteger *navChanged, NSUInteger *removed) {
    if (navChanged) *navChanged = 0;
    if (removed) *removed = 0;
    if (!EB117IsHomeVLP(root)) return root;

    id sanitized = EB117Sanitize(root, removed);
    if (![sanitized isKindOfClass:[NSMutableDictionary class]]) return root;
    NSMutableDictionary *mutableRoot = (NSMutableDictionary *)sanitized;
    NSMutableDictionary *modules = [mutableRoot[@"modules"] isKindOfClass:[NSMutableDictionary class]] ? mutableRoot[@"modules"] : nil;
    if (!modules) return mutableRoot;

    NSUInteger changed = 0;
    for (id key in [modules.allKeys copy]) {
        NSMutableDictionary *module = [modules[key] isKindOfClass:[NSMutableDictionary class]] ? modules[key] : nil;
        if (!module) continue;
        if (![[module[@"_type"] description] isEqualToString:@"NavigationBarModule"]) continue;

        NSArray *containers = [module[@"containers"] isKindOfClass:[NSArray class]] ? module[@"containers"] : nil;
        if (!containers.count) continue;
        id first = containers.firstObject;
        if ([first isKindOfClass:[NSDictionary class]] && first[@"cardContainers"]) continue;

        module[@"containers"] = @[@{ @"cardContainers": containers }];
        changed++;
    }

    if (navChanged) *navChanged = changed;
    return mutableRoot;
}

%hook NSJSONSerialization

+ (id)JSONObjectWithData:(NSData *)data options:(NSJSONReadingOptions)opt error:(NSError **)error {
    id object = %orig;
    if (![object isKindOfClass:[NSDictionary class]]) return object;
    if (!EB117IsHomeVLP((NSDictionary *)object)) return object;

    NSUInteger navChanged = 0;
    NSUInteger removed = 0;
    NSDictionary *adapted = EB117AdaptHome((NSDictionary *)object, &navChanged, &removed);
    EB117Log([NSString stringWithFormat:@"HOME_JSON_COMPAT nav=%lu stripped=%lu modules=%lu",
              (unsigned long)navChanged,
              (unsigned long)removed,
              (unsigned long)[[adapted objectForKey:@"modules"] count]]);
    return adapted ?: object;
}

%end

%ctor {
    if (![[[NSBundle mainBundle] bundleIdentifier] isEqualToString:@"com.ebay.iphone"]) return;
    %init;
}
