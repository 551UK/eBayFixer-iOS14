#import <Foundation/Foundation.h>
#import "Prefs.h"

static BOOL EB142IsHomeVLP(NSDictionary *root) {
    if (![root isKindOfClass:[NSDictionary class]]) return NO;
    NSDictionary *meta = [root[@"meta"] isKindOfClass:[NSDictionary class]] ? root[@"meta"] : nil;
    NSDictionary *pageTemplate = [meta[@"pageTemplate"] isKindOfClass:[NSDictionary class]] ? meta[@"pageTemplate"] : nil;
    return [[[pageTemplate objectForKey:@"templateId"] description] isEqualToString:@"VerticalLandingPage"] &&
           [[root objectForKey:@"modules"] isKindOfClass:[NSDictionary class]];
}

static BOOL EB142Unsupported(NSString *type) {
    return [type isEqualToString:@"SliderControls"] ||
           [type isEqualToString:@"CarouselControls"] ||
           [type isEqualToString:@"EekIcon"];
}

static id EB142Sanitize(id value) {
    if ([value isKindOfClass:[NSDictionary class]]) {
        NSDictionary *source = value;
        NSString *type = [source[@"_type"] isKindOfClass:[NSString class]] ? source[@"_type"] : nil;
        if (type.length && EB142Unsupported(type)) return nil;
        NSMutableDictionary *out = [NSMutableDictionary dictionaryWithCapacity:source.count];
        for (id key in source) {
            id child = EB142Sanitize(source[key]);
            if (child) out[key] = child;
        }
        if ([out[@"controls"] isKindOfClass:[NSDictionary class]] && [out[@"controls"] count] == 0)
            [out removeObjectForKey:@"controls"];
        return out;
    }
    if ([value isKindOfClass:[NSArray class]]) {
        NSMutableArray *out = [NSMutableArray arrayWithCapacity:[value count]];
        for (id child in value) {
            id sanitized = EB142Sanitize(child);
            if (sanitized) [out addObject:sanitized];
        }
        return out;
    }
    return value;
}

%hook NSJSONSerialization
+ (id)JSONObjectWithData:(NSData *)data options:(NSJSONReadingOptions)opt error:(NSError **)error {
    id object = %orig;
    if (![object isKindOfClass:[NSDictionary class]] || !EB142IsHomeVLP(object)) return object;
    id sanitized = EB142Sanitize(object);
    return [sanitized isKindOfClass:[NSDictionary class]] ? sanitized : object;
}
%end

%ctor {
    if (![[[NSBundle mainBundle] bundleIdentifier] isEqualToString:@"com.ebay.iphone"] || !EBPrefsEnabled()) return;
    %init;
}
