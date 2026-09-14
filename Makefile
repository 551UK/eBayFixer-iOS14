ARCHS = arm64 arm64e
TARGET = iphone:clang:14.5:14.0

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = eBayFixer
eBayFixer_FILES = Tweak.xm
eBayFixer_CFLAGS = -fobjc-arc -Wno-deprecated-declarations
eBayFixer_FRAMEWORKS = Foundation UIKit WebKit

include $(THEOS_MAKE_PATH)/tweak.mk
