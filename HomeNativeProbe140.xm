#import <Foundation/Foundation.h>

static NSString *EB140DocumentsPath(NSString *name) {
    NSArray *paths = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
    NSString *dir = paths.firstObject ?: NSTemporaryDirectory();
    return [dir stringByAppendingPathComponent:name];
}

static void EB140Log(NSString *format, ...) {
    va_list args;
    va_start(args, format);
    NSString *message = [[NSString alloc] initWithFormat:format arguments:args];
    va_end(args);
    if (!message.length) return;

    NSString *path = EB140DocumentsPath(@"eBayFixer.log");
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

static BOOL EB140LooksLikeHomeVLP(NSDictionary *root) {
    if (![root isKindOfClass:[NSDictionary class]]) return NO;
    NSDictionary *meta = [root[@"meta"] isKindOfClass:[NSDictionary class]] ? root[@"meta"] : nil;
    NSDictionary *pageTemplate = [meta[@"pageTemplate"] isKindOfClass:[NSDictionary class]] ? meta[@"pageTemplate"] : nil;
    if ([[pageTemplate[@"templateId"] description] isEqualToString:@"VerticalLandingPage"]) return YES;

    NSDictionary *modules = [root[@"modules"] isKindOfClass:[NSDictionary class]] ? root[@"modules"] : nil;
    for (id value in modules.allValues) {
        if (![value isKindOfClass:[NSDictionary class]]) continue;
        NSDictionary *moduleMeta = [value[@"meta"] isKindOfClass:[NSDictionary class]] ? value[@"meta"] : nil;
        NSArray *tracking = [moduleMeta[@"trackingList"] isKindOfClass:[NSArray class]] ? moduleMeta[@"trackingList"] : nil;
        for (id entry in tracking) {
            if (![entry isKindOfClass:[NSDictionary class]]) continue;
            NSDictionary *eventProperty = [entry[@"eventProperty"] isKindOfClass:[NSDictionary class]] ? entry[@"eventProperty"] : nil;
            if ([[eventProperty[@"vlpname"] description] isEqualToString:@"vlp_homepage"]) return YES;
        }
    }
    return NO;
}

static NSString *EB140ModuleSummary(NSDictionary *root) {
    NSDictionary *modules = [root[@"modules"] isKindOfClass:[NSDictionary class]] ? root[@"modules"] : nil;
    NSMutableDictionary<NSString *, NSNumber *> *counts = [NSMutableDictionary dictionary];
    NSMutableArray<NSString *> *pairs = [NSMutableArray array];

    for (NSString *key in modules) {
        id value = modules[key];
        if (![value isKindOfClass:[NSDictionary class]]) continue;
        NSString *type = [value[@"_type"] isKindOfClass:[NSString class]] ? value[@"_type"] : @"(none)";
        counts[type] = @([counts[type] unsignedIntegerValue] + 1);
        [pairs addObject:[NSString stringWithFormat:@"%@=%@", key, type]];
    }

    NSArray *sorted = [[counts allKeys] sortedArrayUsingSelector:@selector(compare:)];
    NSMutableArray *typeParts = [NSMutableArray array];
    for (NSString *type in sorted) {
        [typeParts addObject:[NSString stringWithFormat:@"%@:%@", type, counts[type]]];
    }

    return [NSString stringWithFormat:@"types={%@} modules=[%@]",
            [typeParts componentsJoinedByString:@","],
            [pairs componentsJoinedByString:@","]];
}

%hook NSJSONSerialization

+ (id)JSONObjectWithData:(NSData *)data options:(NSJSONReadingOptions)opt error:(NSError **)error {
    id object = %orig;
    if (![object isKindOfClass:[NSDictionary class]]) return object;
    NSDictionary *root = (NSDictionary *)object;
    if (!EB140LooksLikeHomeVLP(root)) return object;

    NSDictionary *modules = [root[@"modules"] isKindOfClass:[NSDictionary class]] ? root[@"modules"] : nil;
    NSDictionary *meta = [root[@"meta"] isKindOfClass:[NSDictionary class]] ? root[@"meta"] : nil;
    NSDictionary *pageTemplate = [meta[@"pageTemplate"] isKindOfClass:[NSDictionary class]] ? meta[@"pageTemplate"] : nil;

    EB140Log(@"HOME_NATIVE140 response bytes=%lu template=%@ moduleCount=%lu %@",
             (unsigned long)data.length,
             [pageTemplate[@"templateId"] description] ?: @"nil",
             (unsigned long)modules.count,
             EB140ModuleSummary(root));

    // Save the exact, untouched response bytes seen by the native parser.
    // This is diagnostic only; return the original object without mutation.
    @try {
        [data writeToFile:EB140DocumentsPath(@"eBayFixer-HOME-native.json") atomically:YES];
    } @catch (__unused NSException *exception) {}

    return object;
}

%end

%ctor {
    if (![[[NSBundle mainBundle] bundleIdentifier] isEqualToString:@"com.ebay.iphone"]) return;
    %init;
}
