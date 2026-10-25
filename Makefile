ARCHS = arm64 arm64e
TARGET = iphone:clang:latest:15.0
THEOS_PACKAGE_SCHEME = rootless

include $(THEOS)/makefiles/common.mk

SUBPROJECTS += SandyXpc ContraStore contrainstalld ContraRedirect

include $(THEOS_MAKE_PATH)/aggregate.mk
