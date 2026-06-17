#!/usr/bin/env bash
# 重新编译并重启 ClaudePet 桌宠。
# 关键：open 需要接入当前登录用户的图形(Aqua)会话，受限工具进程里直跑 open 会报
# kLSNoExecutableErr。这里用 launchctl asuser 把启动重新投递回用户 GUI 会话，兜底更稳。
set -euo pipefail

cd "$(dirname "$0")"
APP="$PWD/ClaudePet.app"

echo "==> 编译"
./build.sh

echo "==> 停止旧实例"
killall ClaudePet 2>/dev/null || true

echo "==> 启动(投递回用户 GUI 会话)"
UID_NUM="$(id -u)"
LABEL="com.claudepet.restart.$(date +%s)"
if launchctl asuser "$UID_NUM" launchctl submit -l "$LABEL" -- /usr/bin/open -n "$APP" 2>/dev/null; then
  echo "已启动"
elif tail -20 /tmp/claudepet.log 2>/dev/null | grep -q "ClaudePet 启动"; then
  # 某些受限工具会话里 submit 会返回非零,但任务已经投递到 gui/$UID 并完成启动。
  echo "已启动(launchctl submit 返回非零,以应用日志确认为准)"
else
  # 兜底：直接 open(在普通终端/已接入图形会话时可用)。
  open "$APP"
  echo "已启动(直接 open)"
fi
