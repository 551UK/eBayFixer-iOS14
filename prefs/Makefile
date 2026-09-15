ARCHS = arm64 arm64e
TARGET = iphone:clang:14.5:14.0

include $(THEOS)/makefiles/common.mk

BUNDLE_NAME = eBayFixerPrefs
eBayFixerPrefs_FILES = EBRootListController.m
eBayFixerPrefs_FRAMEWORKS = Foundation UIKit CoreFoundation
eBayFixerPrefs_PRIVATE_FRAMEWORKS = Preferences
eBayFixerPrefs_INSTALL_PATH = /Library/PreferenceBundles
eBayFixerPrefs_CFLAGS = -fobjc-arc

include $(THEOS_MAKE_PATH)/bundle.mk
