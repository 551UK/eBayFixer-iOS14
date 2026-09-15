ARCHS = arm64 arm64e
TARGET = iphone:clang:14.5:14.0

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = eBayFixer
eBayFixer_FILES = HomeRoutePatch128.xm HomeGate125.xm Core110.xm KillSwitch.xm HomeCompat.xm NativeItem112.xm NetworkDiag110.xm DCSURLFix134.xm EndpointFix111.xm HomeContract114.xm HomeJSONCompat117.xm HomeSellerCompat135.xm HomeSwiftThrow136.xm HomeRebind137.xm SwiftCall137.S
eBayFixer_CFLAGS = -fobjc-arc -Wno-deprecated-declarations
eBayFixer_FRAMEWORKS = Foundation UIKit

include $(THEOS_MAKE_PATH)/tweak.mk
