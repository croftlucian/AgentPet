#!/bin/bash
# ClaudePet 生命周期通知转发器
# 把 Claude Code / Codex 的生命周期事件,转成一次
#     open "claudepet://<phase>?tool=<claude|codex>&sid=<会话>&cwd=<目录>&task=<简介>"
# 唤起桌宠陪跑:开工(start)进专注态、等确认(waiting)弹横幅提醒、收工(done)庆祝。
# 只读事件与会话记录、只 open 一个自定义 URL,绝不改动任何文件。
#
# 用法(第 2 个参数是 phase,取值 start|waiting|done,缺省 done):
#   Claude Code —— ~/.claude/settings.json 各钩子(事件 JSON 从 stdin 传入):
#       UserPromptSubmit: { "type":"command", "command":"/绝对路径/claudepet-notify.sh claude start" }
#       Notification:     { "type":"command", "command":"/绝对路径/claudepet-notify.sh claude waiting" }
#       Stop:             { "type":"command", "command":"/绝对路径/claudepet-notify.sh claude done" }
#   Codex 0.140+ —— ~/.codex/config.toml 顶部开 codex_hooks = true,再用 inline [hooks](事件 JSON 从 stdin 传入):
#       UserPromptSubmit → start / PermissionRequest → waiting / Stop → done
#       command = ["/绝对路径/claudepet-notify.sh", "codex", "start"]   (waiting/done 同理)
#   兼容旧 Codex notify = ["/绝对路径/claudepet-notify.sh","codex"](事件 JSON 作末位参数):无 phase → 当 done。
#
# 会话标识 sid:优先取事件 JSON 的 session_id(拿不到退回 tool|cwd),桌宠据此聚合多终端并发,
# 任意会话在跑就保持专注,全部收工才歇。cwd 优先取 JSON,缺失则用脚本运行目录(PWD)兜底。
#
# 自测:设 CLAUDEPET_NOTIFY_DRYRUN=1 则只打印将要 open 的 URL,不真正唤起,例如:
#   CLAUDEPET_NOTIFY_DRYRUN=1 ./hooks/claudepet-notify.sh codex start '{"cwd":"/tmp/demo","input-messages":["重构登录模块"]}'

set -u
tool="${1:-claude}"
arg2="${2:-}"

# 区分第 2 参数是 phase(新式 hooks,JSON 走 stdin)还是 JSON(旧式 Codex notify,argv 末位)
raw=""
phase="done"
case "$arg2" in
  start|waiting|done)
    phase="$arg2"
    [ -t 0 ] || raw="$(cat)"          # 新式:JSON 从 stdin 读;仅管道时读,手动跑不阻塞
    ;;
  \{*)
    raw="$arg2"                       # 旧式 Codex notify:argv 末位是 JSON,无 phase → done
    ;;
  *)
    [ -t 0 ] || raw="$(cat)"          # 空或脏值:当 done,stdin 有就读(手动测试无 JSON 也放行)
    ;;
esac

# 旧式 Codex notify 只发 agent-turn-complete 一种完成事件(别的/空不报喜);
# 新式 hooks 的 Stop 事件本身即收工,无需此过滤。
case "$arg2" in
  \{*)
    case "$tool" in
      codex|cx)
        case "$raw" in
          *agent-turn-complete*) ;;
          *) exit 0 ;;
        esac
        ;;
    esac
    ;;
esac

# 用 python3 解析事件、(Claude)扒 transcript,拼出最终 URL
url="$(printf '%s' "$raw" | CPET_TOOL="$tool" CPET_PHASE="$phase" python3 -c '
import os, sys, json, urllib.parse

tool = os.environ.get("CPET_TOOL", "claude")
phase = os.environ.get("CPET_PHASE", "done")
raw = sys.stdin.read()
try:
    data = json.loads(raw) if raw.strip() else {}
except Exception:
    data = {}
if not isinstance(data, dict):
    data = {}

# 工作目录:事件里没有就退回脚本运行目录(hooks 通常在项目目录下执行)
cwd = data.get("cwd") or data.get("workdir") or os.environ.get("PWD") or os.getcwd()

# 会话标识:拿不到稳定 id 就用 工具|目录 兜底,保证多终端并发能分得清
sid = (data.get("session_id") or data.get("session")
       or data.get("thread_id") or data.get("conversation_id") or "")
if not sid:
    sid = "%s|%s" % (tool, cwd)

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
    # Claude:UserPromptSubmit 事件直接带 prompt;否则顺 transcript 扒最近一条主公的纯文本输入
    task = (data.get("prompt") or "").strip()
    if not task:
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
print("claudepet://%s?tool=%s&sid=%s&cwd=%s&task=%s"
      % (q(phase), q(tool), q(sid, safe=""), q(cwd), q(task)))
')"

# python3 缺失或异常导致 url 为空时,降级为只带 phase 与 tool,保证功能不哑火
if [ -z "$url" ]; then
  url="claudepet://${phase}?tool=${tool}"
fi

if [ -n "${CLAUDEPET_NOTIFY_DRYRUN:-}" ]; then
  printf '%s\n' "$url"
  exit 0
fi

/usr/bin/open "$url"
exit 0
