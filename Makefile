#
#  XHSNative
#
#  Copyright (c) 2026 huami. All rights reserved.
#  Channel: @huamidev
#  Created on: 2026/11/24
#
# make                          只出 dylib，给注入 IPA 用
# make package                  无根 deb
# make package SCHEME=roothide  roothide deb，需要 roothide/theos
-include Makefile.local

TARGET = iphone:clang:latest:15.0
ARCHS = arm64 arm64e

# 不出有根的包。普通的 make 不设方案，注入用的 dylib 不带越狱路径
ifeq ($(SCHEME),roothide)
    export THEOS_PACKAGE_SCHEME = roothide
else ifneq ($(filter package,$(MAKECMDGOALS)),)
    export THEOS_PACKAGE_SCHEME = rootless
endif

export DEBUG = 0
INSTALL_TARGET_PROCESSES = discover

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = XHSNative
RELEASE_VERSION := $(shell awk -F'"' '/define XHSNativeVersion / {sub(/[^0-9.].*/, "", $$2); print $$2}' XHSNativeConfig.h)
PACKAGE_VERSION = $(RELEASE_VERSION)

XHSNative_FILES = XHSNative.xm XHSNativeLegacyHooks.xm XHSNativeHelper.m XHSNativeConfig.m XHSNativeSave.m XHSNativeLegacy.m XHSNativeViewState.m Artwork.S
XHSNative_CFLAGS = -fobjc-arc -w
XHSNative_STRIP_FLAGS = -x
XHSNative_FRAMEWORKS = UIKit QuartzCore Photos AVFoundation CoreMedia ImageIO
XHSNative_LDFLAGS = -Wl,-install_name,@rpath/XHSNative.dylib
XHSNative_LOGOS_DEFAULT_GENERATOR = internal

include $(THEOS_MAKE_PATH)/tweak.mk

# dylib 放到 packages 目录。打 deb 时的产物只进 deb，不覆盖它
after-all::
ifeq ($(THEOS_PACKAGE_SCHEME),)
	@mkdir -p packages
	@cp $(THEOS_OBJ_DIR)/$(TWEAK_NAME).dylib packages/$(TWEAK_NAME)-$(RELEASE_VERSION).dylib
	@echo -e "\033[32m==>\033[0m packages/$(TWEAK_NAME)-$(RELEASE_VERSION).dylib"
endif

clean::
	@rm -rf .theos packages
