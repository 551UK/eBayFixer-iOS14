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

static BOOL EB123DataContains(NSData *data, NSString *needle) {
    if (!data.length || !needle.length) return NO;
    NSData *bytes = [needle dataUsingEncoding:NSUTF8StringEncoding];
    if (!bytes.length || bytes.length > data.length) return NO;
    return [data rangeOfData:bytes options:0 range:NSMakeRange(0, data.length)].location != NSNotFound;
}

static BOOL EB123IsF90Key(NSString *value) {
    return [value isEqualToString:@"homescreen.vlpF90"];
}

static BOOL EB123IsKillKey(NSString *value) {
    return [value isEqualToString:@"homescreen.vlpF90KillSwitch"];
}

static void EB123SetToggleRecord(NSMutableDictionary *dict, BOOL enabled, NSUInteger *patched) {
    BOOL changed = NO;
    NSArray *fields = @[@"value", @"defaultValue", @"boolValue", @"enabled", @"isEnabled", @"remoteValue", @"overrideValue"];
    for (NSString *field in fields) {
        if (dict[field] != nil) {
            dict[field] = @(enabled);
            changed = YES;
        }
    }
    if (!changed) dict[@"value"] = @(enabled);
    if (patched) (*patched)++;
}

static id EB123PatchFeatureConfig(id value, NSUInteger *patched) {
    if ([value isKindOfClass:[NSDictionary class]]) {
        NSDictionary *source = (NSDictionary *)value;
        NSMutableDictionary *out = [source mutableCopy];

        for (NSString *key in [out.allKeys copy]) {
            if (![key isKindOfClass:[NSString class]]) continue;
            if (EB123IsF90Key(key)) {
                out[key] = @YES;
                if (patched) (*patched)++;
            } else if (EB123IsKillKey(key)) {
                out[key] = @NO;
                if (patched) (*patched)++;
            }
        }

        NSString *recordKey = nil;
        for (NSString *candidate in @[@"key", @"name", @"identifier", @"id"]) {
            id candidateValue = out[candidate];
            if ([candidateValue isKindOfClass:[NSString class]]) {
                NSString *stringValue = (NSString *)candidateValue;
                if (EB123IsF90Key(stringValue) || EB123IsKillKey(stringValue)) {
                    recordKey = stringValue;
                    break;
                }
            }
        }
        if (recordKey) EB123SetToggleRecord(out, EB123IsF90Key(recordKey), patched);

        for (id key in [out.allKeys copy]) {
            id child = out[key];
            id patchedChild = EB123PatchFeatureConfig(child, patched);
            if (patchedChild) out[key] = patchedChild;
        }
        return out;
    }

    if ([value isKindOfClass:[NSArray class]]) {
        NSMutableArray *out = [NSMutableArray arrayWithCapacity:[(NSArray *)value count]];
        for (id child in (NSArray *)value) {
            id patchedChild = EB123PatchFeatureConfig(child, patched);
            [out addObject:patchedChild ?: [NSNull null]];
        }
        return out;
    }

    return value;
}

%hook NSJSONSerialization

+ (id)JSONObjectWithData:(NSData *)data options:(NSJSONReadingOptions)opt error:(NSError **)error {
    id object = %orig;
    if (!object) return object;

    BOOL mayContainHomeToggle = EB123DataContains(data, @"vlpF90") || EB123DataContains(data, @"vlpF90KillSwitch");
    if (mayContainHomeToggle) {
        NSUInteger patched = 0;
        id patchedObject = EB123PatchFeatureConfig(object, &patched);
        if (patched > 0) {
            object = patchedObject ?: object;
            EB117Log([NSString stringWithFormat:@"HOME_DCS_TOGGLE patched=%lu", (unsigned long)patched]);
        }
    }

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

%hook NSUserDefaults

- (BOOL)boolForKey:(NSString *)defaultName {
    if (EB123IsF90Key(defaultName)) {
        EB117Log(@"HOME_DEFAULTS_READ homescreen.vlpF90 -> 1");
        return YES;
    }
    if (EB123IsKillKey(defaultName)) {
        EB117Log(@"HOME_DEFAULTS_READ homescreen.vlpF90KillSwitch -> 0");
        return NO;
    }
    NSString *lower = defaultName.lowercaseString ?: @"";
    if ([lower containsString:@"vlp"] || [lower containsString:@"verticallanding"]) {
        EB117Log([NSString stringWithFormat:@"HOME_DEFAULTS_READ observed=%@", defaultName ?: @"(nil)"]);
    }
    return %orig;
}

- (void)setBool:(BOOL)value forKey:(NSString *)defaultName {
    if (EB123IsF90Key(defaultName)) {
        EB117Log(@"HOME_DEFAULTS_WRITE homescreen.vlpF90 forced=1");
        %orig(YES, defaultName);
        return;
    }
    if (EB123IsKillKey(defaultName)) {
        EB117Log(@"HOME_DEFAULTS_WRITE homescreen.vlpF90KillSwitch forced=0");
        %orig(NO, defaultName);
        return;
    }
    NSString *lower = defaultName.lowercaseString ?: @"";
    if ([lower containsString:@"vlp"] || [lower containsString:@"verticallanding"]) {
        EB117Log([NSString stringWithFormat:@"HOME_DEFAULTS_WRITE observed=%@ value=%d", defaultName ?: @"(nil)", value]);
    }
    %orig;
}

%end

%ctor {
    if (![[[NSBundle mainBundle] bundleIdentifier] isEqualToString:@"com.ebay.iphone"]) return;
    %init;
}
