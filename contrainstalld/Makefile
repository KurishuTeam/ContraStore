include $(THEOS)/makefiles/common.mk

TOOL_NAME = contrainstalld
contrainstalld_SWIFT_MODULE_NAME = contrainstalld
contrainstalld_FILES = $(wildcard *.swift *.m *.c)
contrainstalld_INSTALL_PATH = /usr/libexec
contrainstalld_FRAMEWORKS = Foundation
contrainstalld_LIBRARIES = sqlite3

include $(THEOS_MAKE_PATH)/tool.mk
