#!/bin/sh
set -eu
project_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
test_dir=$(mktemp -d /tmp/xhsnative-tests.XXXXXX)
trap 'rm -rf "$test_dir"' EXIT HUP INT TERM
mkdir -p "$test_dir/UIKit"
cat > "$test_dir/UIKit/UIKit.h" << 'EOF'
#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>
@class UIView, UIViewController, UIControl;
EOF
xcrun --sdk macosx clang -fobjc-arc -Wall -Wextra -Werror -Wno-unused-parameter \
    -framework Foundation -framework CoreGraphics -I"$test_dir" -I"$project_dir" \
    "$project_dir/XHSNativeViewState.m" "$project_dir/XHSNativeConfig.m" \
    "$project_dir/tests/state-config-tests.m" -o "$test_dir/tests"
"$test_dir/tests"
