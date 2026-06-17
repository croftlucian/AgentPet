#!/usr/bin/env bash
# 编译 Claude 桌面宠物并组装成 macOS .app 包
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
APP="$ROOT/ClaudePet.app"
MACOS="$APP/Contents/MacOS"
BIN="$MACOS/ClaudePet"
CACHE="$ROOT/.build/module-cache"
RESOURCES="$APP/Contents/Resources"

echo "==> 清理旧产物"
rm -rf "$APP"
mkdir -p "$MACOS" "$RESOURCES" "$CACHE"

echo "==> 编译 Swift 源码(Swift 5 模式,规避严格并发误报)"
swiftc -swift-version 5 -O \
  -module-cache-path "$CACHE" \
  "$ROOT/Sources/main.swift" \
  -framework AppKit \
  -o "$BIN"

echo "==> 写入 Info.plist"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>zh_CN</string>
    <key>CFBundleDisplayName</key>
    <string>ClaudePet</string>
    <key>CFBundleExecutable</key>
    <string>ClaudePet</string>
    <key>CFBundleIdentifier</key>
    <string>com.claude.pet</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>ClaudePet</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <!-- 后台附件应用:不在 Dock 显示,不抢焦点 -->
    <key>LSUIElement</key>
    <true/>
    <key>LSMinimumSystemVersion</key>
    <string>13.0</string>
</dict>
</plist>
PLIST
printf 'APPL????' > "$APP/Contents/PkgInfo"

echo "==> 写入 cx 包装命令"
cat > "$RESOURCES/cx" <<'SH'
#!/usr/bin/env zsh
exec /opt/homebrew/bin/codex --dangerously-bypass-approvals-and-sandbox "$@"
SH
chmod +x "$RESOURCES/cx"

echo "==> ad-hoc 代码签名"
codesign --force --sign - "$APP" 2>/dev/null && echo "（签名完成）" || echo "（签名跳过,不影响本机运行）"

echo "==> 完成:$APP"
echo "    启动:open \"$APP\""
