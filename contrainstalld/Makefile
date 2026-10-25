include $(THEOS)/makefiles/common.mk

TOOL_NAME = contrainstalld
contrainstalld_FILES = $(wildcard Database/*.swift Installer/*.swift Common/*.c Zip/*.c) main.m
contrainstalld_INSTALL_PATH = /usr/libexec
contrainstalld_FRAMEWORKS = Foundation
contrainstalld_LIBRARIES = sqlite3 SandyXpc
contrainstalld_CFLAGS = -I. -Iinclude -I$(THEOS_PROJECT_DIR)/SandyXpc -I$(THEOS_PROJECT_DIR)/SandyXpc/include
contrainstalld_SWIFT_BRIDGING_HEADER = include/contrainstalld-Bridging-Header.h

include $(THEOS_MAKE_PATH)/tool.mk
