#!/bin/bash
# 建置 build/TouchBarLyrics.app（只需 Command Line Tools，不需 Xcode）
set -euo pipefail
cd "$(dirname "$0")"

APP=build/TouchBarLyrics.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"

xcrun swiftc -O -swift-version 5 \
    -framework AppKit \
    Sources/*.swift \
    -o "$APP/Contents/MacOS/TouchBarLyrics"

cp Info.plist "$APP/Contents/Info.plist"
codesign --force --sign - "$APP"

echo "完成：$APP"
