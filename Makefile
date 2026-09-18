ARCHS = arm64 arm64e
TARGET = iphone:clang:14.5:14.0

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = eBayFixer
eBayFixer_FILES = Core110.xm KillSwitch.xm HomeGate125.xm HomeCompat.xm HomeRoutePatch128.xm HomeContract114.xm HomeUnsupportedTypeCompat142.xm HomeFix.xm HomeSwiftBridge144.S EndpointFix111.xm NativeItem112.xm ItemActionCompat156.xm
eBayFixer_CFLAGS = -fobjc-arc -Wno-deprecated-declarations
eBayFixer_FRAMEWORKS = Foundation UIKit

include $(THEOS_MAKE_PATH)/tweak.mk

SUBPROJECTS += prefs
include $(THEOS_MAKE_PATH)/aggregate.mk
