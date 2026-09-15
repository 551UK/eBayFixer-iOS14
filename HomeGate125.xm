#import <Foundation/Foundation.h>

static BOOL EB125IsHomeVLPEnabledKey(NSString *key) {
    return [key isKindOfClass:[NSString class]] && [key isEqualToString:@"isHomeVLPEnabled"];
}

%hook NSUserDefaults

- (BOOL)boolForKey:(NSString *)defaultName {
    if (EB125IsHomeVLPEnabledKey(defaultName)) return YES;
    return %orig;
}

- (id)objectForKey:(NSString *)defaultName {
    if (EB125IsHomeVLPEnabledKey(defaultName)) return @YES;
    return %orig;
}

- (void)setBool:(BOOL)value forKey:(NSString *)defaultName {
    if (EB125IsHomeVLPEnabledKey(defaultName)) {
        %orig(YES, defaultName);
        return;
    }
    %orig;
}

- (void)setObject:(id)value forKey:(NSString *)defaultName {
    if (EB125IsHomeVLPEnabledKey(defaultName)) {
        %orig(@YES, defaultName);
        return;
    }
    %orig;
}

%end

%ctor {
    @autoreleasepool {
        if (![[[NSBundle mainBundle] bundleIdentifier] isEqualToString:@"com.ebay.iphone"]) return;
        %init;
        [[NSUserDefaults standardUserDefaults] setBool:YES forKey:@"isHomeVLPEnabled"];
    }
}
