#import <Foundation/Foundation.h>

static inline BOOL EBPrefsEnabled(void) {
    NSDictionary *prefs = [NSDictionary dictionaryWithContentsOfFile:@"/var/mobile/Library/Preferences/com.551.ebayfixer.plist"];
    id value = prefs[@"enabled"];
    return value ? [value boolValue] : YES;
}
