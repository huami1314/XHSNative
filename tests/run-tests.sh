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

afconvert /System/Library/Sounds/Ping.aiff "$test_dir/ping.m4a" -f m4af -d aac -b 64000
fixture="${XHSNATIVE_AUDIO_TEST_VIDEO:-}"
if [ -z "$fixture" ]; then
    ffmpeg_bin="${FFMPEG:-$(command -v ffmpeg || true)}"
    if [ -n "$ffmpeg_bin" ]; then
        "$ffmpeg_bin" -hide_banner -loglevel error -y \
            -f lavfi -i "testsrc=size=320x240:rate=30:duration=3" \
            -f lavfi -i "sine=frequency=440:sample_rate=44100:duration=3" \
            -c:v libx264 -pix_fmt yuv420p -c:a aac -b:a 64000 \
            -shortest "$test_dir/fixture.mp4"
        fixture="$test_dir/fixture.mp4"
    fi
fi
if [ -n "$fixture" ] && [ -f "$fixture" ]; then
    xcrun --sdk macosx clang -fobjc-arc -Wall -Wextra -Werror -Wno-unused-parameter \
        -Wno-deprecated-declarations -framework Foundation -framework AVFoundation \
        -framework CoreMedia -framework CoreAudio -framework AudioToolbox \
        "$project_dir/tests/live-photo-audio-tests.m" -o "$test_dir/audio-tests"
    "$test_dir/audio-tests" "$fixture" "$test_dir/ping.m4a"
else
    echo "skip: live photo audio test needs FFMPEG or XHSNATIVE_AUDIO_TEST_VIDEO"
fi
