ARCHS = arm64 arm64e
TARGET = iphone:clang:latest:15.0
THEOS_PACKAGE_SCHEME = rootless

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = WatusiScheduledMsgFixSB

WatusiScheduledMsgFixSB_FILES = BulletinBridge.xm
WatusiScheduledMsgFixSB_CFLAGS = -fobjc-arc -Wno-unused-function
WatusiScheduledMsgFixSB_FRAMEWORKS = Foundation

include $(THEOS_MAKE_PATH)/tweak.mk

TOOL_NAME = WatusiShortcutSend WatusiShortcutSendCore

WatusiShortcutSend_FILES = NetworkGate.m
WatusiShortcutSend_CFLAGS = -fobjc-arc -Wno-unused-function
WatusiShortcutSend_FRAMEWORKS = Foundation

WatusiShortcutSendCore_FILES = ShortcutsSend.m
WatusiShortcutSendCore_CFLAGS = -fobjc-arc -Wno-unused-function
WatusiShortcutSendCore_FRAMEWORKS = Foundation
WatusiShortcutSendCore_CODESIGN_FLAGS = -SShortcutsSend.entitlements

include $(THEOS_MAKE_PATH)/tool.mk
