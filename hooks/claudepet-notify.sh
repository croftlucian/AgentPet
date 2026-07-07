#!/bin/bash
# 兼容旧版 hook 配置:项目已更名为 AgentPet,旧 claudepet-notify.sh 入口转发到新脚本。
DIR="$(cd "$(dirname "$0")" && pwd)"
exec "$DIR/agentpet-notify.sh" "$@"
