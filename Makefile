ARCHS = arm64 arm64e
TARGET = iphone:clang:latest:15.0
THEOS_PACKAGE_SCHEME = rootless

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = WatusiScheduledMsgFixSB WatusiScheduledMsgFixCallServices

WatusiScheduledMsgFixSB_FILES = SpringBoard.xm
WatusiScheduledMsgFixSB_CFLAGS = -fobjc-arc
WatusiScheduledMsgFixSB_FRAMEWORKS = Foundation

WatusiScheduledMsgFixCallServices_FILES = CallServices.xm
WatusiScheduledMsgFixCallServices_CFLAGS = -fobjc-arc
WatusiScheduledMsgFixCallServices_FRAMEWORKS = Foundation

include $(THEOS_MAKE_PATH)/tweak.mk
