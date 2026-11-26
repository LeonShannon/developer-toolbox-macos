#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")"
app="开发工具箱.app"
binary="$app/Contents/MacOS/DeveloperToolbox"

mkdir -p "$app/Contents/MacOS"

echo "正在编译 Sources/*.swift..."
xcrun swiftc -target "$(uname -m)-apple-macos13.0" -O Sources/*.swift -o "$binary"

echo "正在重签 $app..."
codesign --force --sign - "$app"

echo "正在运行自检..."
"$binary" --check

echo "构建与自检完成。"
