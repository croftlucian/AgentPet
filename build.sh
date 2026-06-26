#!/usr/bin/env bash
# 编译 AgentPet 桌面宠物并组装成 macOS .app 包
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
APP="$ROOT/AgentPet.app"
MACOS="$APP/Contents/MacOS"
BIN="$MACOS/AgentPet"
CACHE="$ROOT/.build/module-cache"
RESOURCES="$APP/Contents/Resources"
INSTALL_APP="${INSTALL_APP:-/Applications/AgentPet.app}"
OPEN_AFTER_BUILD="${OPEN_AFTER_BUILD:-1}"

echo "==> 清理旧产物"
rm -rf "$APP"
mkdir -p "$MACOS" "$RESOURCES" "$CACHE"

echo "==> 编译 Swift 源码(Swift 5 模式,规避严格并发误报)"
swiftc -swift-version 5 -O \
  -module-cache-path "$CACHE" \
  "$ROOT/Sources/main.swift" \
  "$ROOT/Sources/RemoteControl.swift" \
  "$ROOT/Sources/FeishuRemote.swift" \
  "$ROOT/Sources/TaskMonitor.swift" \
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
    <string>AgentPet</string>
    <key>CFBundleExecutable</key>
    <string>AgentPet</string>
    <key>CFBundleIdentifier</key>
    <string>com.agent.pet</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>AgentPet</string>
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
    <!-- 自定义 URL 协议:Claude Code / Codex 完成任务后 open "agentpet://done?..." 唤起桌宠报喜 -->
    <key>CFBundleURLTypes</key>
    <array>
        <dict>
            <key>CFBundleURLName</key>
            <string>com.agent.pet.feed</string>
            <key>CFBundleURLSchemes</key>
            <array>
                <string>agentpet</string>
            </array>
        </dict>
    </array>
</dict>
</plist>
PLIST
printf 'APPL????' > "$APP/Contents/PkgInfo"

echo "==> 写入 cc / cx 包装命令(投喂优先用它们 = 官方命令 + 跳过确认参数,对应主公的 cc/cx 别名)"
if compgen -G "$ROOT/Resources/*.png" >/dev/null; then
  echo "==> 复制图片资源"
  cp "$ROOT"/Resources/*.png "$RESOURCES"/
fi

cat > "$RESOURCES/cc" <<'SH'
#!/usr/bin/env zsh
exec /opt/homebrew/bin/claude --dangerously-skip-permissions "$@"
SH
chmod +x "$RESOURCES/cc"
cat > "$RESOURCES/cx" <<'SH'
#!/usr/bin/env zsh
exec /opt/homebrew/bin/codex --dangerously-bypass-approvals-and-sandbox "$@"
SH
chmod +x "$RESOURCES/cx"

echo "==> code signing"
SIGN_IDENTITY="${SIGN_IDENTITY:-}"
if [[ -z "$SIGN_IDENTITY" ]]; then
  SIGN_IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null | awk -F '"' '/AgentPet Local Code Signing/ {print $2; exit}')"
fi
if [[ -z "$SIGN_IDENTITY" ]]; then
  SIGN_IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null | awk -F '"' '/Apple Development/ {print $2; exit}')"
fi
if [[ -z "$SIGN_IDENTITY" ]]; then
  SIGN_IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null | awk -F '"' '/^[[:space:]]*[0-9]+\\)/ {print $2; exit}')"
fi
if [[ -n "$SIGN_IDENTITY" ]]; then
  codesign --force --sign "$SIGN_IDENTITY" "$APP" 2>/dev/null && echo "(signed with identity: ${SIGN_IDENTITY})" || echo "(identity signing failed)"
else
  codesign --force --sign - "$APP" 2>/dev/null && echo "(ad-hoc signed;未找到稳定签名身份,macOS 可能要求重新授予辅助功能/完全磁盘访问)" || echo "(signing skipped)"
fi

if [[ -n "$INSTALL_APP" ]]; then
  echo "==> 安装到 $INSTALL_APP"
  if pgrep -x AgentPet >/dev/null 2>&1; then
    pkill -x AgentPet || true
    sleep 1
  fi
  rm -rf "$INSTALL_APP"
  ditto "$APP" "$INSTALL_APP"
  echo "==> 已安装:$INSTALL_APP"
fi

if [[ "$OPEN_AFTER_BUILD" == "1" && -n "$INSTALL_APP" ]]; then
  echo "==> 启动 $INSTALL_APP"
  open "$INSTALL_APP"
fi

echo "==> 完成:$APP"
if [[ -n "$INSTALL_APP" ]]; then
  echo "    正式启动:open \"$INSTALL_APP\""
else
  echo "    启动:open \"$APP\""
fi
