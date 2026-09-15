ARCHS = arm64 arm64e
TARGET = iphone:clang:14.5:14.0

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = eBayFixer
eBayFixer_FILES = HomeRoutePatch128.xm HomeGate125.xm Core110.xm KillSwitch.xm HomeCompat.xm NativeItem112.xm NetworkDiag110.xm HomeNativeProbe140.xm HomeUnsupportedTypeCompat142.xm HomeRuntimeState147.xm HomeExactRepair148.xm HomeSwiftBridge144.S DCSURLFix134.xm EndpointFix111.xm HomeContract114.xm
eBayFixer_CFLAGS = -fobjc-arc -Wno-deprecated-declarations
eBayFixer_FRAMEWORKS = Foundation UIKit

include $(THEOS_MAKE_PATH)/tweak.mk
