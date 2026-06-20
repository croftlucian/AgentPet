#!/bin/bash
# ClaudePet 生命周期通知转发器
# 把 Claude Code / Codex 的生命周期事件,转成一次
#     open "claudepet://<phase>?tool=<claude|codex>&sid=<会话>&cwd=<目录>&task=<简介>&tty=<终端设备>&ts=<事件时间戳>&pid=<会话进程pid>"
# 唤起桌宠陪跑:开工(start)进专注态、等确认(waiting)弹横幅提醒、收工(done)庆祝。
# 只读事件与会话记录、只 open 一个自定义 URL,绝不改动任何文件。
#
# 用法(第 2 个参数是 phase,取值 start|waiting|done,缺省 done):
#   Claude Code —— ~/.claude/settings.json 各钩子(事件 JSON 从 stdin 传入):
#       UserPromptSubmit: { "type":"command", "command":"/绝对路径/claudepet-notify.sh claude start" }
#       Notification:     { "type":"command", "command":"/绝对路径/claudepet-notify.sh claude waiting" }
#       Stop:             { "type":"command", "command":"/绝对路径/claudepet-notify.sh claude done" }
#       StopFailure:      { "type":"command", "command":"/绝对路径/claudepet-notify.sh claude done" }
#       注:Stop 只在正常答完时触发;网络/接口报错、重试耗尽那轮走 StopFailure(Claude Code 2.1.78+),
#           两个都接 done,角标「跑 N」才不会卡到 10 分钟超时才清。本脚本按 argv 定相位,done 直接复用。
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

# 探测承载本会话的终端 tty:hook 自身的 stdin 多半是管道(读不到 tty),
# 故沿父进程链上爬,取第一个挂着真实 tty 的祖先(即那个 shell / claude / codex 进程),
# 规范成 /dev/ttysXXX 交给桌宠,点横幅时据此精确回到这一个终端窗口。拿不到则留空,退回整 App 唤前台。
detect_tty() {
  local pid="$$" tt ppid n=0
  while [ "$n" -lt 12 ]; do
    tt="$(ps -o tty= -p "$pid" 2>/dev/null | tr -d '[:space:]')"
    case "$tt" in
      ttys*|tty[0-9]*) printf '/dev/%s' "$tt"; return 0 ;;
    esac
    ppid="$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d '[:space:]')"
    [ -z "$ppid" ] && return 0
    [ "$ppid" -le 1 ] 2>/dev/null && return 0
    pid="$ppid"
    n=$((n + 1))
  done
  return 0
}
session_tty="$(detect_tty)"

# 探测承载本会话的 claude/codex 进程 pid:沿父进程链上爬,取第一个 comm 基名为 claude/codex 的祖先。
# hook 由 claude/codex 作为子进程调起,故其祖先链必含该会话进程。桌宠据此 kill -0 探活——
# 进程一退出(硬退出/崩溃/被杀/关终端都不触发收工钩子)即清角标,不必干等 10 分钟超时兜底。
# 拿不到则留空,桌宠退回纯超时兜底(老 hook 不带 pid 时同此,功能不哑火)。
detect_session_pid() {
  local pid="$$" comm bn ppid n=0
  while [ "$n" -lt 16 ]; do
    comm="$(ps -o comm= -p "$pid" 2>/dev/null)"
    bn="${comm##*/}"                 # 取基名,去路径
    bn="${bn#-}"                     # 去登录 shell 的前导 -
    case "$bn" in
      claude|codex) printf '%s' "$pid"; return 0 ;;
    esac
    ppid="$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d '[:space:]')"
    [ -z "$ppid" ] && return 0
    [ "$ppid" -le 1 ] 2>/dev/null && return 0
    pid="$ppid"
    n=$((n + 1))
  done
  return 0
}
session_pid="$(detect_session_pid)"

# 用 python3 解析事件、(Claude)扒 transcript,拼出最终 URL
url="$(printf '%s' "$raw" | CPET_TOOL="$tool" CPET_PHASE="$phase" CPET_TTY="$session_tty" CPET_SPID="$session_pid" python3 -c '
import os, sys, json, time, urllib.parse

tool = os.environ.get("CPET_TOOL", "claude")
phase = os.environ.get("CPET_PHASE", "done")
tty = os.environ.get("CPET_TTY", "")
spid = os.environ.get("CPET_SPID", "")
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
# ts:事件生成时刻(epoch 秒)。hook 一发即走、LaunchServices 不保证按序投递,桌宠据此对同一 sid 的乱序事件定序去旧。
# pid:承载本会话的 claude/codex 进程 pid(可空),桌宠超时兜底前先 kill(0) 探活,进程退出即清角标。
print("claudepet://%s?tool=%s&sid=%s&cwd=%s&task=%s&tty=%s&ts=%s%s"
      % (q(phase), q(tool), q(sid, safe=""), q(cwd), q(task), q(tty, safe=""), time.time(),
         ("&pid=" + q(spid, safe="")) if spid else ""))
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
