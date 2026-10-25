include $(THEOS)/makefiles/common.mk

LIBRARY_NAME = ContraRedirect
ContraRedirect_FILES = Tweak.x $(THEOS_PROJECT_DIR)/Shared/Common.m
contraredirect_FILES = $(ContraRedirect_FILES)
ContraRedirect_INSTALL_PATH = /usr/lib
ContraRedirect_FRAMEWORKS = UIKit Foundation
ContraRedirect_LIBRARIES = SandyXpc
contraredirect_LIBRARIES = $(ContraRedirect_LIBRARIES)
ContraRedirect_CFLAGS = -I$(THEOS_PROJECT_DIR)/Shared -I$(THEOS_PROJECT_DIR)/SandyXpc -I$(THEOS_PROJECT_DIR)/SandyXpc/include
contraredirect_CFLAGS = $(ContraRedirect_CFLAGS)

include $(THEOS_MAKE_PATH)/library.mk
