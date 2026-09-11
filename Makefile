ARCHS = arm64 arm64e
TARGET = iphone:clang:latest:15.0
THEOS_PACKAGE_SCHEME = rootless

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = WatusiScheduledMsgFix
WatusiScheduledMsgFix_FILES = Tweak.xm
WatusiScheduledMsgFix_CFLAGS = -fobjc-arc
WatusiScheduledMsgFix_FRAMEWORKS = Foundation

TOOL_NAME = WatusiScheduledMsgDaemon
WatusiScheduledMsgDaemon_FILES = Daemon.m
WatusiScheduledMsgDaemon_CFLAGS = -fobjc-arc -fblocks
WatusiScheduledMsgDaemon_FRAMEWORKS = Foundation
WatusiScheduledMsgDaemon_INSTALL_PATH = /usr/libexec

include $(THEOS_MAKE_PATH)/tweak.mk
include $(THEOS_MAKE_PATH)/tool.mk
