#
#  XHSNative
#
#  Copyright (c) 2026 huami. All rights reserved.
#  Channel: @huamidev
#  Created on: 2026/11/24
#

TARGET = iphone:clang:latest:15.0
ARCHS = arm64

export DEBUG = 0

include $(THEOS)/makefiles/common.mk

LIBRARY_NAME = XHSNative
RELEASE_VERSION := $(shell awk -F'"' '/define XHSNativeVersion / {sub(/[^0-9.].*/, "", $$2); print $$2}' XHSNativeConfig.h)

XHSNative_FILES = XHSNative.xm XHSNativeLegacyHooks.xm XHSNativeHelper.m XHSNativeConfig.m XHSNativeSave.m XHSNativeLegacy.m XHSNativeViewState.m Artwork.S
XHSNative_CFLAGS = -fobjc-arc -w
XHSNative_STRIP_FLAGS = -x
XHSNative_FRAMEWORKS = UIKit QuartzCore Photos
XHSNative_LDFLAGS = -Wl,-install_name,@rpath/XHSNative.dylib
XHSNative_LOGOSFLAGS = -c generator=internal

include $(THEOS_MAKE_PATH)/library.mk

# 产物放到 packages 目录
after-all::
	@mkdir -p packages
	@cp $(THEOS_OBJ_DIR)/$(LIBRARY_NAME).dylib packages/$(LIBRARY_NAME)-$(RELEASE_VERSION).dylib
	@echo -e "\033[32m==>\033[0m packages/$(LIBRARY_NAME)-$(RELEASE_VERSION).dylib"

clean::
	@rm -rf .theos packages
