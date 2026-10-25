include $(THEOS)/makefiles/common.mk

TOOL_NAME = contrainstalld
contrainstalld_FILES = $(wildcard Common/*.swift Installer/*.swift Zip/*.c Zip/*.swift) main.m
contrainstalld_INSTALL_PATH = /usr/libexec
contrainstalld_FRAMEWORKS = Foundation
contrainstalld_LIBRARIES = sqlite3
contrainstalld_CFLAGS = -Iinclude
contrainstalld_SWIFT_BRIDGING_HEADER = include/contrainstalld-Bridging-Header.h


include $(THEOS_MAKE_PATH)/tool.mk
