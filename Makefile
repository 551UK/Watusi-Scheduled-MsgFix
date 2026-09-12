ARCHS = arm64 arm64e
TARGET = iphone:clang:latest:15.0
THEOS_PACKAGE_SCHEME = rootless

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = WatusiScheduledMsgFixSB WatusiScheduledMsgFixWA

WatusiScheduledMsgFixSB_FILES = BulletinBridge.xm
WatusiScheduledMsgFixSB_CFLAGS = -fobjc-arc
WatusiScheduledMsgFixSB_FRAMEWORKS = Foundation

WatusiScheduledMsgFixWA_FILES = ScheduleMirror.xm
WatusiScheduledMsgFixWA_CFLAGS = -fobjc-arc
WatusiScheduledMsgFixWA_FRAMEWORKS = Foundation

include $(THEOS_MAKE_PATH)/tweak.mk

TOOL_NAME = WatusiShortcutSend
WatusiShortcutSend_FILES = ShortcutsSend.m
WatusiShortcutSend_CFLAGS = -fobjc-arc -Wno-unused-but-set-variable
WatusiShortcutSend_FRAMEWORKS = Foundation
WatusiShortcutSend_CODESIGN_FLAGS = -SShortcutsSend.entitlements

include $(THEOS_MAKE_PATH)/tool.mk
