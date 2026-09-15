#import <Foundation/Foundation.h>
#import <dlfcn.h>
#import <execinfo.h>
#import <substrate.h>
#import <unistd.h>
#import <fcntl.h>
#import <string.h>
#import <stdio.h>

static void (*EB136OrigSwiftWillThrow)(void *error) = NULL;
static __thread int EB136InHook = 0;

static void EB136AppendLine(const char *line) {
    if (!line || !*line) return;
    NSArray *paths = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
    NSString *dir = paths.firstObject ?: NSTemporaryDirectory();
    NSString *path = [dir stringByAppendingPathComponent:@"eBayFixer.log"];
    int fd = open(path.fileSystemRepresentation, O_WRONLY | O_CREAT | O_APPEND, 0644);
    if (fd < 0) return;
    write(fd, line, strlen(line));
    close(fd);
}

static void EB136SwiftWillThrow(void *error) {
    if (!EB136InHook) {
        EB136InHook = 1;
        void *frames[48] = {0};
        int count = backtrace(frames, 48);
        char line[4096];
        size_t used = 0;
        BOOL foundHome = NO;

        used += (size_t)snprintf(line + used, sizeof(line) - used,
                                 "HOME_THROW136 error=%p frames=", error);

        for (int i = 1; i < count && used < sizeof(line) - 128; i++) {
            Dl_info info;
            memset(&info, 0, sizeof(info));
            if (!dladdr(frames[i], &info) || !info.dli_fname || !info.dli_fbase) continue;
            const char *name = strrchr(info.dli_fname, '/');
            name = name ? name + 1 : info.dli_fname;
            if (strcmp(name, "HomePageModule") != 0) continue;

            foundHome = YES;
            uintptr_t offset = (uintptr_t)frames[i] - (uintptr_t)info.dli_fbase;
            used += (size_t)snprintf(line + used, sizeof(line) - used,
                                     "%s0x%lx", used > 37 ? "," : "",
                                     (unsigned long)offset);
        }

        if (foundHome && used < sizeof(line) - 2) {
            line[used++] = '\n';
            line[used] = '\0';
            EB136AppendLine(line);
        }
        EB136InHook = 0;
    }

    if (EB136OrigSwiftWillThrow) EB136OrigSwiftWillThrow(error);
}

%ctor {
    @autoreleasepool {
        if (![[[NSBundle mainBundle] bundleIdentifier] isEqualToString:@"com.ebay.iphone"]) return;
        void *target = dlsym(RTLD_DEFAULT, "swift_willThrow");
        if (target) {
            MSHookFunction(target, (void *)&EB136SwiftWillThrow, (void **)&EB136OrigSwiftWillThrow);
            EB136AppendLine("HOME_THROW136 hook_installed=1\n");
        } else {
            EB136AppendLine("HOME_THROW136 hook_installed=0\n");
        }
    }
}
