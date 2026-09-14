#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <substrate.h>

// eBay 6.96 HomeTabCoordinator Swift metadata, verified from its field descriptor:
// fields: navController, authStateObserver, cancelable, currentUseCase,
// authCancelable, lazy vlpFlowController, lazy vlpViewController, lazy homeViewController.
// FieldOffsetVectorOffset = 39 words; currentUseCase field index = 3.
static const NSUInteger EB120FieldVectorWordOffset = 39;
static const NSUInteger EB120CurrentUseCaseIndex = 3;
static const NSUInteger EB120ExpectedFieldCount = 8;
static const NSUInteger EB120ExpectedInstanceSize = 200;

static Class EB120CoordinatorClass = Nil;
static id (*EB120OrigNSObjectInit)(id, SEL) = NULL;
static BOOL EB120HookInstalled = NO;
static BOOL EB120LoggedMetadata = NO;

static NSString *EB120LogPath(void) {
    NSArray *paths = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
    NSString *dir = paths.firstObject ?: NSTemporaryDirectory();
    return [dir stringByAppendingPathComponent:@"eBayFixer.log"];
}

static void EB120Log(NSString *format, ...) {
    if (!format) return;
    va_list args;
    va_start(args, format);
    NSString *message = [[NSString alloc] initWithFormat:format arguments:args];
    va_end(args);
    if (!message.length) return;

    NSString *line = [NSString stringWithFormat:@"%@ %@\n", [NSDate date], message];
    NSString *path = EB120LogPath();
    if (![[NSFileManager defaultManager] fileExistsAtPath:path]) {
        [[NSFileManager defaultManager] createFileAtPath:path contents:nil attributes:nil];
    }
    NSFileHandle *handle = [NSFileHandle fileHandleForWritingAtPath:path];
    if (!handle) return;
    @try {
        [handle seekToEndOfFile];
        [handle writeData:[line dataUsingEncoding:NSUTF8StringEncoding]];
        [handle closeFile];
    } @catch (__unused NSException *exception) {}
}

static BOOL EB120GetFieldOffsets(Class cls, uint32_t outOffsets[EB120ExpectedFieldCount]) {
    if (!cls || !outOffsets) return NO;
    if (class_getInstanceSize(cls) != EB120ExpectedInstanceSize) return NO;

    uint8_t *metadata = (uint8_t *)(__bridge void *)cls;
    uint32_t *vector = (uint32_t *)(metadata + (EB120FieldVectorWordOffset * sizeof(void *)));

    uint32_t previous = 0;
    for (NSUInteger i = 0; i < EB120ExpectedFieldCount; i++) {
        uint32_t offset = vector[i];
        if (offset >= EB120ExpectedInstanceSize) return NO;
        if (i && offset < previous) return NO;
        outOffsets[i] = offset;
        previous = offset;
    }
    return YES;
}

static void EB120ForceCoordinator(id coordinator, NSString *reason) {
    Class target = EB120CoordinatorClass;
    if (!target || !coordinator || object_getClass(coordinator) != target) return;

    uint32_t offsets[EB120ExpectedFieldCount] = {0};
    if (!EB120GetFieldOffsets(target, offsets)) {
        EB120Log(@"HOME_ROUTE_FORCE metadata_validation_failed size=%zu", class_getInstanceSize(target));
        return;
    }

    if (!EB120LoggedMetadata) {
        EB120LoggedMetadata = YES;
        EB120Log(@"HOME_ROUTE_META offsets=%u,%u,%u,%u,%u,%u,%u,%u size=%zu",
                 offsets[0], offsets[1], offsets[2], offsets[3],
                 offsets[4], offsets[5], offsets[6], offsets[7],
                 class_getInstanceSize(target));
    }

    uint32_t useCaseOffset = offsets[EB120CurrentUseCaseIndex];
    uint8_t *storage = ((uint8_t *)(__bridge void *)coordinator) + useCaseOffset;
    uint8_t before = *storage;

    // HomePageUseCase is a no-payload 3-case enum in 6.96:
    // answers=0, vlp=1, none=2. Only write when the stored discriminator is sane.
    if (before > 2) {
        EB120Log(@"HOME_ROUTE_FORCE refused offset=%u discriminator=%u reason=%@",
                 useCaseOffset, before, reason ?: @"-");
        return;
    }

    *storage = 1;
    EB120Log(@"HOME_ROUTE_FORCE offset=%u before=%u after=%u reason=%@",
             useCaseOffset, before, *storage, reason ?: @"-");
}

static id EB120NSObjectInit(id self, SEL _cmd) {
    id result = EB120OrigNSObjectInit ? EB120OrigNSObjectInit(self, _cmd) : self;
    Class target = EB120CoordinatorClass;
    if (target && result && object_getClass(result) == target) {
        EB120ForceCoordinator(result, @"NSObject.init");
        id retainedCoordinator = result;
        dispatch_async(dispatch_get_main_queue(), ^{
            EB120ForceCoordinator(retainedCoordinator, @"post-init");
        });
    }
    return result;
}

static void EB120ResolveCoordinator(void) {
    Class cls = NSClassFromString(@"_TtC14HomePageModule18HomeTabCoordinator");
    if (cls) EB120CoordinatorClass = cls;
}

%ctor {
    @autoreleasepool {
        if (![[[NSBundle mainBundle] bundleIdentifier] isEqualToString:@"com.ebay.iphone"]) return;

        EB120ResolveCoordinator();

        if (!EB120HookInstalled) {
            EB120HookInstalled = YES;
            MSHookMessageEx([NSObject class], @selector(init), (IMP)EB120NSObjectInit, (IMP *)&EB120OrigNSObjectInit);
        }

        for (NSNumber *delay in @[@0.05, @0.15, @0.5, @1.0, @2.0]) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay.doubleValue * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{ EB120ResolveCoordinator(); });
        }
    }
}
