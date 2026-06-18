#!/bin/bash
# ClaudePet 任务完成通知转发器
# 把 Claude Code(Stop 钩子)/ Codex(notify)的完成事件,转成一次
#     open "claudepet://done?tool=<claude|codex>&cwd=<目录>&task=<任务简介>"
# 唤起桌宠弹横幅报喜。只读事件与会话记录、只 open 一个自定义 URL,绝不改动任何文件。
#
# 用法:
#   Claude Code —— ~/.claude/settings.json 的 Stop 钩子(事件 JSON 从 stdin 传入,含 cwd 与 transcript_path):
#       { "type": "command", "command": "/绝对路径/hooks/claudepet-notify.sh claude" }
#   Codex —— ~/.codex/config.toml(notify 须放在所有 [表] 之前;事件 JSON 作为末位参数传入):
#       notify = ["/绝对路径/hooks/claudepet-notify.sh", "codex"]
#
# 任务简介来源:Codex 取事件里的 input-messages(主公交代的话);Claude 顺 transcript_path
# 扒会话记录里最近一条主公的纯文本输入。取不到就只带目录名,桌宠端再兜底。
#
# 自测:设 CLAUDEPET_NOTIFY_DRYRUN=1 则只打印将要 open 的 URL,不真正唤起,例如:
#   CLAUDEPET_NOTIFY_DRYRUN=1 ./hooks/claudepet-notify.sh codex '{"type":"agent-turn-complete","cwd":"/tmp/demo","input-messages":["重构登录模块"]}'

set -u
tool="${1:-claude}"

# 取原始事件 JSON:Codex 在第二个参数,Claude 从 stdin
raw=""
case "$tool" in
  codex|cx)
    raw="${2:-}"
    # Codex 目前只发 agent-turn-complete 一种完成事件;别的(或空)不报喜
    case "$raw" in
      *agent-turn-complete*) ;;
      "") ;;                       # 手动测试无 JSON 也放行
      *) exit 0 ;;
    esac
    ;;
  *)
    [ -t 0 ] || raw="$(cat)"        # 仅当 stdin 是管道才读,手动跑不阻塞
    ;;
esac

# 用 python3 解析事件、(Claude)扒 transcript,拼出最终 URL
url="$(printf '%s' "$raw" | CPET_TOOL="$tool" python3 -c '
import os, sys, json, urllib.parse

tool = os.environ.get("CPET_TOOL", "claude")
raw = sys.stdin.read()
try:
    data = json.loads(raw) if raw.strip() else {}
except Exception:
    data = {}
if not isinstance(data, dict):
    data = {}

cwd = data.get("cwd") or ""
task = ""

def text_from_content(content):
    if isinstance(content, str):
        return content
    if isinstance(content, list):
        return "".join(c.get("text", "") for c in content
                       if isinstance(c, dict) and c.get("type") == "text")
    return ""

if tool in ("codex", "cx"):
    msgs = data.get("input-messages") or []
    if isinstance(msgs, list):
        task = " ".join(str(m) for m in msgs)
    elif isinstance(msgs, str):
        task = msgs
    if not task.strip():
        task = data.get("last-assistant-message") or ""
else:
    tp = data.get("transcript_path") or ""
    if tp and os.path.isfile(tp):
        last = ""
        try:
            with open(tp, encoding="utf-8") as f:
                for line in f:
                    line = line.strip()
                    if not line:
                        continue
                    try:
                        o = json.loads(line)
                    except Exception:
                        continue
                    if o.get("type") != "user":
                        continue
                    t = text_from_content((o.get("message") or {}).get("content")).strip()
                    # 排除工具结果(无 text 自然为空)与命令/系统注入(尖括号包裹)
                    if t and not t.startswith("<"):
                        last = t
            task = last
        except Exception:
            task = ""

task = " ".join(task.split())          # 压平换行与多余空白
if len(task) > 60:
    task = task[:60] + "…"

q = urllib.parse.quote
print("claudepet://done?tool=%s&cwd=%s&task=%s" % (q(tool), q(cwd), q(task)))
')"

# python3 缺失或异常导致 url 为空时,降级为只带 tool,保证功能不哑火
if [ -z "$url" ]; then
  url="claudepet://done?tool=${tool}"
fi

if [ -n "${CLAUDEPET_NOTIFY_DRYRUN:-}" ]; then
  printf '%s\n' "$url"
  exit 0
fi

/usr/bin/open "$url"
exit 0
