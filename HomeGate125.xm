#import <Foundation/Foundation.h>

static NSString *EB125LogPath(void) {
    NSArray *paths = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
    NSString *dir = paths.firstObject ?: NSTemporaryDirectory();
    return [dir stringByAppendingPathComponent:@"eBayFixer.log"];
}

static void EB125Log(NSString *line) {
    if (!line.length) return;
    NSString *path = EB125LogPath();
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

static BOOL EB125IsHomeVLPEnabledKey(NSString *key) {
    return [key isKindOfClass:[NSString class]] && [key isEqualToString:@"isHomeVLPEnabled"];
}

%hook NSUserDefaults

- (BOOL)boolForKey:(NSString *)defaultName {
    if (EB125IsHomeVLPEnabledKey(defaultName)) {
        EB125Log(@"HOME_GATE boolForKey isHomeVLPEnabled -> 1");
        return YES;
    }
    return %orig;
}

- (id)objectForKey:(NSString *)defaultName {
    if (EB125IsHomeVLPEnabledKey(defaultName)) {
        EB125Log(@"HOME_GATE objectForKey isHomeVLPEnabled -> 1");
        return @YES;
    }
    return %orig;
}

- (void)setBool:(BOOL)value forKey:(NSString *)defaultName {
    if (EB125IsHomeVLPEnabledKey(defaultName)) {
        EB125Log([NSString stringWithFormat:@"HOME_GATE setBool isHomeVLPEnabled requested=%d forced=1", value]);
        %orig(YES, defaultName);
        return;
    }
    %orig;
}

- (void)setObject:(id)value forKey:(NSString *)defaultName {
    if (EB125IsHomeVLPEnabledKey(defaultName)) {
        EB125Log(@"HOME_GATE setObject isHomeVLPEnabled forced=1");
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

        // Seed the exact persistent gate observed in device logs before Home initializes.
        NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
        [defaults setBool:YES forKey:@"isHomeVLPEnabled"];
        [defaults synchronize];
        EB125Log(@"HOME_GATE seeded isHomeVLPEnabled=1");
    }
}
