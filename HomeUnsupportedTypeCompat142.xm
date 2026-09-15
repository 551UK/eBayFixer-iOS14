#import <Foundation/Foundation.h>

static NSString *EB142LogPath(void) {
    NSArray *paths = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
    NSString *dir = paths.firstObject ?: NSTemporaryDirectory();
    return [dir stringByAppendingPathComponent:@"eBayFixer.log"];
}

static void EB142Log(NSString *format, ...) {
    if (!format) return;
    va_list args;
    va_start(args, format);
    NSString *message = [[NSString alloc] initWithFormat:format arguments:args];
    va_end(args);
    if (!message.length) return;

    NSString *path = EB142LogPath();
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

static BOOL EB142IsHomeVLP(NSDictionary *root) {
    if (![root isKindOfClass:[NSDictionary class]]) return NO;
    NSDictionary *meta = [root[@"meta"] isKindOfClass:[NSDictionary class]] ? root[@"meta"] : nil;
    NSDictionary *pageTemplate = [meta[@"pageTemplate"] isKindOfClass:[NSDictionary class]] ? meta[@"pageTemplate"] : nil;
    return [[[pageTemplate objectForKey:@"templateId"] description] isEqualToString:@"VerticalLandingPage"] &&
           [[root objectForKey:@"modules"] isKindOfClass:[NSDictionary class]];
}

typedef struct {
    NSUInteger slider;
    NSUInteger carousel;
    NSUInteger eek;
} EB142Counts;

static BOOL EB142IsUnsupportedType(NSString *type, EB142Counts *counts) {
    if ([type isEqualToString:@"SliderControls"]) {
        if (counts) counts->slider++;
        return YES;
    }
    if ([type isEqualToString:@"CarouselControls"]) {
        if (counts) counts->carousel++;
        return YES;
    }
    if ([type isEqualToString:@"EekIcon"]) {
        if (counts) counts->eek++;
        return YES;
    }
    return NO;
}

static id EB142Sanitize(id value, EB142Counts *counts) {
    if ([value isKindOfClass:[NSDictionary class]]) {
        NSDictionary *source = (NSDictionary *)value;
        NSString *type = [source[@"_type"] isKindOfClass:[NSString class]] ? source[@"_type"] : nil;
        if (type.length && EB142IsUnsupportedType(type, counts)) return nil;

        NSMutableDictionary *out = [NSMutableDictionary dictionaryWithCapacity:source.count];
        for (id key in source) {
            id child = EB142Sanitize(source[key], counts);
            if (child) out[key] = child;
        }

        // The three removed control objects can leave an empty controls map.
        // Old eBay does not need an empty placeholder, so drop it cleanly.
        id controls = out[@"controls"];
        if ([controls isKindOfClass:[NSDictionary class]] && [(NSDictionary *)controls count] == 0) {
            [out removeObjectForKey:@"controls"];
        }
        return out;
    }

    if ([value isKindOfClass:[NSArray class]]) {
        NSMutableArray *out = [NSMutableArray arrayWithCapacity:[(NSArray *)value count]];
        for (id child in (NSArray *)value) {
            id sanitized = EB142Sanitize(child, counts);
            if (sanitized) [out addObject:sanitized];
        }
        return out;
    }

    return value;
}

%hook NSJSONSerialization

+ (id)JSONObjectWithData:(NSData *)data options:(NSJSONReadingOptions)opt error:(NSError **)error {
    id object = %orig;
    if (![object isKindOfClass:[NSDictionary class]] || !EB142IsHomeVLP((NSDictionary *)object)) return object;

    EB142Counts counts = {0, 0, 0};
    id sanitized = EB142Sanitize(object, &counts);
    if (![sanitized isKindOfClass:[NSDictionary class]]) return object;

    NSDictionary *root = (NSDictionary *)sanitized;
    NSDictionary *modules = [root[@"modules"] isKindOfClass:[NSDictionary class]] ? root[@"modules"] : nil;
    EB142Log(@"HOME_TYPES142 stripped slider=%lu carousel=%lu eek=%lu modules=%lu",
             (unsigned long)counts.slider,
             (unsigned long)counts.carousel,
             (unsigned long)counts.eek,
             (unsigned long)modules.count);

    // Keep this bridge deliberately narrow: no navigation reshaping, no seller
    // discriminator injection, no feature-toggle changes and no loader hooks.
    return sanitized;
}

%end

%ctor {
    if (![[[NSBundle mainBundle] bundleIdentifier] isEqualToString:@"com.ebay.iphone"]) return;
    %init;
}
