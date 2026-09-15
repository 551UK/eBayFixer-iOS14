#import <Foundation/Foundation.h>

static NSString *EB135LogPath(void) {
    NSArray *paths = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
    NSString *dir = paths.firstObject ?: NSTemporaryDirectory();
    return [dir stringByAppendingPathComponent:@"eBayFixer.log"];
}

static void EB135Log(NSString *format, ...) {
    if (!format) return;
    va_list args;
    va_start(args, format);
    NSString *message = [[NSString alloc] initWithFormat:format arguments:args];
    va_end(args);
    if (!message.length) return;

    NSString *path = EB135LogPath();
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

static BOOL EB135IsHomeVLP(NSDictionary *root) {
    if (![root isKindOfClass:[NSDictionary class]]) return NO;
    NSDictionary *meta = [root[@"meta"] isKindOfClass:[NSDictionary class]] ? root[@"meta"] : nil;
    NSDictionary *pageTemplate = [meta[@"pageTemplate"] isKindOfClass:[NSDictionary class]] ? meta[@"pageTemplate"] : nil;
    return [[[pageTemplate objectForKey:@"templateId"] description] isEqualToString:@"VerticalLandingPage"] &&
           [[root objectForKey:@"modules"] isKindOfClass:[NSDictionary class]];
}

static id EB135BridgeNode(id value, NSUInteger *patched) {
    if ([value isKindOfClass:[NSDictionary class]]) {
        NSDictionary *source = (NSDictionary *)value;
        NSMutableDictionary *out = [source mutableCopy];

        NSString *type = [out[@"_type"] isKindOfClass:[NSString class]] ? out[@"_type"] : nil;
        if ([type isEqualToString:@"SellerCardContainer"] && out[@"name"] == nil) {
            // eBay 6.96's PersonalizedItemsModuleTransformer requires
            // containers.0.cardContainers.0.name to be ITEM_CARD_LIST or
            // ITEM_CARD_CAROUSEL before it dispatches to the seller transformer.
            // Current Home payloads omit that legacy discriminator entirely.
            out[@"name"] = @"ITEM_CARD_CAROUSEL";
            if (patched) (*patched)++;
        }

        for (id key in [out.allKeys copy]) {
            id child = out[key];
            id bridged = EB135BridgeNode(child, patched);
            if (bridged) out[key] = bridged;
        }
        return out;
    }

    if ([value isKindOfClass:[NSArray class]]) {
        NSMutableArray *out = [NSMutableArray arrayWithCapacity:[(NSArray *)value count]];
        for (id child in (NSArray *)value) {
            id bridged = EB135BridgeNode(child, patched);
            [out addObject:bridged ?: [NSNull null]];
        }
        return out;
    }

    return value;
}

%hook NSJSONSerialization

+ (id)JSONObjectWithData:(NSData *)data options:(NSJSONReadingOptions)opt error:(NSError **)error {
    id object = %orig;
    if (![object isKindOfClass:[NSDictionary class]] || !EB135IsHomeVLP((NSDictionary *)object)) return object;

    NSDictionary *root = (NSDictionary *)object;
    NSDictionary *modules = [root[@"modules"] isKindOfClass:[NSDictionary class]] ? root[@"modules"] : nil;
    BOOL hasPersonalizedItems = NO;
    for (id moduleValue in modules.allValues) {
        if (![moduleValue isKindOfClass:[NSDictionary class]]) continue;
        if ([[moduleValue[@"_type"] description] isEqualToString:@"ADS_AND_MERCH_LIST_V2"]) {
            hasPersonalizedItems = YES;
            break;
        }
    }
    if (!hasPersonalizedItems) return object;

    NSUInteger patched = 0;
    id bridged = EB135BridgeNode(object, &patched);
    EB135Log(@"HOME_SELLER135 legacy_name_bridge patched=%lu", (unsigned long)patched);
    return bridged ?: object;
}

%end

%ctor {
    if (![[[NSBundle mainBundle] bundleIdentifier] isEqualToString:@"com.ebay.iphone"]) return;
    %init;
}
