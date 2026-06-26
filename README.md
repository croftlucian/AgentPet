# AgentPet · macOS 桌面宠物

在屏幕角落浮一只手绘的星芒,安静呼吸。把文件拖给它、按快捷键喂它、双击问它一句,它会"张嘴咀嚼",随后在终端唤起 `claude` / `codex` 交互会话替你干活;还能陪跑 Claude Code / Codex 的生命周期、提示微信飞书未读、随手翻译选中文字。

- 纯本地、最少权限:看清靠星芒自带的描边光晕兜底,**不截屏、不读聊天正文**;本机投喂只读取、不改文件(唯一例外是下方「远程遥控」——它跳过权限确认、真能改文件跑命令,默认关闭、需自行开启)。
- 核心逻辑在 `Sources/main.swift`(AppKit),远程遥控独立成 `Sources/RemoteControl.swift`(Telegram)与 `Sources/FeishuRemote.swift`(飞书),任务监控独立成 `Sources/TaskMonitor.swift`(落盘 + 本地仪表盘),四文件由 `build.sh` 一起编进同一二进制;无 Xcode 工程、无 SwiftPM。

> 桌宠内右键「使用说明…」可随手查看精简版;本文是完整版。

---

## 快捷键(全局,任何应用里都生效)

| 快捷键 | 作用 |
| --- | --- |
| **⌥⌘C** | 把 Finder 当前选中的文件/目录喂给 **cc** 分析 |
| **⌥⌘X** | 把 Finder 当前选中的文件/目录喂给 **Codex** 分析 |
| **⌥⌘B** | 把**剪贴板里的文字**喂给 cc 开会话 |
| **⌥⌘T** | 翻译选中的文字(中文↔英文,自动判向),桌宠头顶气泡显示 |

快捷键经 Carbon 注册,后台附件应用即可全局生效,免辅助功能权限(取选中文字的 ⌥⌘T 需要辅助功能权限)。

---

## 投喂:让 cc / cx 替你看东西

桌宠"吃"东西 = 触发分析,**只读取、绝不移动或删改文件**。

- **拖文件/目录**到桌宠身上 → 喂给 cc。
- **⌥⌘C / ⌥⌘X** → 取 Finder 选中项喂 cc / cx。桌宠会**扑到鼠标处**张嘴嚼一口,再滑回原位、在终端开会话。
- **双击桌宠**,或**右键「问 cc…/问 Codex…」** → 弹出多行输入框,打一句话或贴一段报错,在家目录开会话。
- 投喂优先用桌宠内置的 `cc` / `cx` 包装命令(= 官方命令 + 跳过确认参数),没有再退到 PATH 里的 `claude` / `codex`。因此投喂进去的活儿**跳过权限确认**直接干。
- 终端优先用 [Ghostty](https://ghostty.org)(`ghostty -e`),没装则回退系统默认终端。

---

## 鼠标互动

| 操作 | 反应 |
| --- | --- |
| 悬停 | 眯眼笑 + 鼓起来呼吸 + 发光 + 蹦一下 |
| 单击身体 | 吃一口(咀嚼一下) |
| 双击身体 | 弹输入框问 cc |
| 按住身体拖动 | 把桌宠挪到屏幕别处 |
| 右键 | 菜单:设置 / 远程遥控(Telegram / 飞书) / 问一句 / 使用说明 / 测试提示 / 退出 |

空闲时还会自己眨眼、东张西望、摇晃、打哈欠。

---

## 陪跑 Claude Code / Codex

桌宠跟随 Claude Code / Codex 的生命周期变换状态(需接入下方通知钩子):

- **开工**(你发问)→ 进专注态,呼吸变快。
- **等待回答**(cc 停下等你确认时)→ 弹琥珀横幅 + 角标显「等N」(点横幅可回现场);答完一轮则收工、不再显示。
- **收工**(答完一轮)→ 弹报喜横幅。
- **会话角标**:星芒右上角显示「跑N·等N」(跑=正在执行、等=cc 停下等你回答),多终端并发一目了然;答完一轮即消失(设置里可关)。
- **点横幅回现场**:点"报喜/等确认"横幅,精确把发起该会话的那个终端窗口唤回前台——多个终端窗口并发时也能跳到正确的那一个(支持 Ghostty / iTerm2 / 系统终端;认不出对应窗口时退回唤起终端 App,没有终端在跑则用访达打开该目录)。

> 注意:`Stop` / `agent-turn-complete` 是"每答完一轮就触发",并非整任务完成(两个 CLI 都没有"整任务完成"信号)。

### 接入通知钩子

陪跑/报喜靠 `agentpet://` 协议唤起。把 `hooks/agentpet-notify.sh`(已 `chmod +x`)接进**用户级**配置:

**Claude Code** —— `~/.claude/settings.json`(事件 JSON 从 stdin 传入):

```json
{
  "hooks": {
    "UserPromptSubmit": [{ "hooks": [{ "type": "command", "command": "/绝对路径/hooks/agentpet-notify.sh claude start" }] }],
    "Notification":     [{ "hooks": [{ "type": "command", "command": "/绝对路径/hooks/agentpet-notify.sh claude waiting" }] }],
    "Stop":             [{ "hooks": [{ "type": "command", "command": "/绝对路径/hooks/agentpet-notify.sh claude done" }] }],
    "StopFailure":      [{ "hooks": [{ "type": "command", "command": "/绝对路径/hooks/agentpet-notify.sh claude done" }] }]
  }
}
```

> `Stop` 只在正常答完时触发;网络/接口报错、重试耗尽那一轮走的是 `StopFailure`(Claude Code 2.1.78+)。两个都接到 `claude done`,角标的「跑 N」才不会卡住——少了 `StopFailure`,报错那轮永远收不到收工、会一直占着「跑」直到超时清理。此外,客户端进程被强杀、崩溃或超时硬退出(连 `StopFailure` 都来不及发)时,桌宠会探测承载该会话的进程是否还活着,进程一退出即清角标,不必干等超时。

**Codex** —— `~/.codex/config.toml`。新式(0.140+)在顶部开 `codex_hooks = true` 后用 inline `[hooks]`,把 `UserPromptSubmit / PermissionRequest / Stop` 分别接到 `claude start/waiting/done` 的 `codex` 版;或用旧式 `notify`(只报收工):

```toml
notify = ["/绝对路径/hooks/agentpet-notify.sh", "codex"]
```

桌宠须在运行中;首次 `open AgentPet.app` 后系统才登记 `agentpet://` 协议。设 `AGENTPET_NOTIFY_DRYRUN=1` 跑脚本只打印 URL、不真正唤起,便于核对。

---

## 远程遥控(Telegram / 飞书)

不在电脑前也能支使 cc/cx 干活:在手机给 bot 发一句话,桌宠在本机非交互跑 `cc`(Claude)/ `cx`(Codex),干完把结果回传聊天。**Telegram、飞书两条渠道并存**,Telegram 的 cc/cx 可各填多枚 bot token(适合每人一个专属 bot),飞书的 cc/cx 各占一个应用——各记各的上下文。

> ⚠️ 它**跳过权限确认、真能改文件跑命令**(与本机 `cc` / `cx` 一脉)。务必设白名单只让自己用。功能默认关闭(Telegram 与飞书共用「启用远程遥控」总开关),token / app secret 只存本机、不入仓库。

会话各自记上下文(claude 走 `--resume`、codex 走 `exec resume`),像真聊天般连续。桌宠收到指令 / 答完一轮会闪横幅,远程有动静在电脑前也看得见。

**首次个性化设置**:每个远程用户在每个平台、每个 bot 内都有独立配置。首次使用或旧 bot 尚未设置时,普通问题会被拦截,必须先完成个性化设置:回复数字 `1` 一步步设置,或回复数字 `2` 用一段话快速设置。例如:“你叫德全,称呼我为主公,说话恭敬一点,但不要太啰嗦。”设置完成后,后续回复会带上 bot 名字、对用户的称呼和说话风格。设置不支持跳过,默认风格是“正常”。

**一次性新功能公告**:安装新版并启动后,如果已启用远程遥控、配置了 Telegram token + chat id 白名单,或飞书 App 凭证 + open_id 白名单,桌宠会向每个已配置 bot 的白名单会话自动推送一次个性化设置说明。每台电脑、每个平台、每个 bot、每个会话对同一公告版本只发一次;白名单为空时不推送。

**实时进度**:发出消息后,bot 先回一条占位消息,随后把 cc/cx 干活的关键步骤(在读哪个文件、跑什么命令、中间说了啥)实时刷进这条消息;最终答复另发一条。进度面板自带节流。（飞书侧单条消息可编辑次数有限,刷到上限即停更进度,最终答复照常另发。）

**聊天里的指令**(两条渠道通用):

| 指令 | 作用 |
| --- | --- |
| 直接发消息 | 当成 prompt 交给 cc/cx 干活,干完回话 |
| `/cd <路径>` | 切换工作目录(并开新会话) |
| `/pwd` | 看当前工作目录 |
| `/new` | 开新会话(清空上下文) |
| `/setup` | 重新设置当前用户当前 Bot |
| `/profile` | 查看当前用户当前 Bot 设置 |
| `/reset` | 清空当前用户当前 Bot 设置并重新引导 |
| `/help` | 查看指令 |

详细到每条命令、每个配置字段和本地排查命令的说明见 [远程遥控使用说明](docs/remote-control-usage.md)。

### Telegram 启用步骤

1. Telegram 找 [@BotFather](https://t.me/BotFather) 建 bot;要每个人独立入口,就给每个人各建一枚 cc bot token,需要 cx 时再各建一枚 cx bot token;
2. 右键桌宠 →「远程遥控(Telegram / 飞书)…」→ 勾「启用远程遥控」,把多枚 token 填进 `cc bot tokens` / `Codex(cx)bot tokens` 字段,用逗号或空格分隔;
3. 先给每个 bot 发一条消息,用 `getUpdates` 看到自己的 chat id,填进「允许的 chat id 白名单」(**强烈建议**,否则任何人都能遥控你的 Mac);
4. 点「保存并应用」即生效;留空对应 token 列表的那一类 bot 不启动。

### 飞书启用步骤(仅国内版 open.feishu.cn,国际版 Lark 不支持长连接)

1. 到[飞书开放平台](https://open.feishu.cn)建 **两个** 企业自建应用(一个给 cc、一个给 cx),各拿 **App ID** 与 **App Secret**;
2. 每个应用:添加「**机器人**」能力;在「权限管理」开通 `im:message`(收发消息)相关权限;
3. 「事件订阅」里订阅方式选 **长连接**,订阅事件「**接收消息 `im.message.receive_v1`**」;把应用**发布版本**、在企业内可用;
4. 右键桌宠 →「远程遥控(Telegram / 飞书)…」→ 勾「启用远程遥控」、填 cc/cx 两套 App ID + App Secret;
5.(**强烈建议**)填「允许的 open_id 白名单」只让自己用;点「保存并应用」即生效,凭证留空的那个应用不启动。

> 飞书走「长连接(WebSocket)」纯出站、无需公网回调,和 Telegram 一样在内网/笔记本即可用。**私聊**直接发消息;**群里**需 **@机器人** 才响应。

---

## 任务监控

把**远程遥控**每轮"问题→答案"连同发起人、墙钟耗时、CLI 自报花费 / token 落盘成 JSONL,并起一个本地仪表盘方便回看。**默认关闭**。

- 开启后浏览器访问 `http://127.0.0.1:8722`(端口可在设置里改)查看任务记录与统计。
- 数据落在 `~/Library/Application Support/com.agent.pet/monitor/tasks.jsonl`;用系统自带网络库**只监听 `127.0.0.1`**,纯本地、不对外。
- 只覆盖**远程遥控**两条链路(Telegram / 飞书);本机投喂(拖放 / 快捷键 / 双击)交给终端、进程内拿不到答案与发起人,故不记录。
- 设置里可填「前端目录」挂载自定义仪表盘页面;留空则用内置单文件页面,开箱即用、不依赖 Node 构建。

> 在主设置窗顶部「任务监控」组开启,并设仪表盘端口与前端目录。

---

## 作息脾气

- **会饿会蔫**:久没人搭理就缩着身子、慢呼吸、垂眼;摸一下 / 喂一下即回血。
- **久坐提醒**:固定间隔(可调)弹横幅催你起身。
- **深夜犯困**:深夜时段多打哈欠。

---

## 通知横幅

- **微信**(绿)/**飞书**(蓝)未读:只读 Dock 角标判断有无未读和粗略数量,**不读数据库、不解密、不存聊天正文**。需辅助功能权限。
- **任务完成**(橙):cc / cx 答完一轮报喜。
- **免打扰**:一键静音所有被动提示(微信/飞书/等确认/收工/久坐);你主动按 ⌥⌘T 翻译、点菜单测试的不受影响,会话角标也照常显示。

---

## 设置(右键「设置...」)

| 分组 | 可调项 |
| --- | --- |
| 任务监控 | 挂载监控系统(记录远程任务并起本地页面)、仪表盘端口、前端目录 |
| 权限 | 完全磁盘访问、辅助功能的开启状态 + 一键前往系统设置开启(自动化首次用到时自动弹窗) |
| 划词翻译 | 启用 ⌥⌘T 翻译 |
| 互动 | 移动速度(扑食滑行)、手动颜色、自动适应环境色 |
| 陪跑 | 开工进专注、等确认提醒、任务完成提示、显示会话角标 |
| 作息脾气 | 会饿会蔫、久坐提醒(+间隔)、深夜犯困 |
| 通知 | 接收微信、接收飞书、免打扰 |
| 窗口 | 停靠角(四角)、开机自启 |

颜色看清主要靠星芒描边轮廓兜底;自动配色跟随系统深浅模式与强调色,**不触碰屏幕内容、无需屏幕录制权限**。

---

## 构建与运行

```bash
./build.sh                 # swiftc 编译 + 组装 .app + 写 Info.plist + 签名
open /Applications/AgentPet.app # 启动桌宠
```

- 要求 macOS 13.0+、已装 Xcode Command Line Tools(`swiftc`)。
- `build.sh` 默认会把新版本覆盖安装到 `/Applications/AgentPet.app` 并启动这份正式 app;如只想生成项目内 app,可用 `INSTALL_APP= OPEN_AFTER_BUILD=0 ./build.sh`。
- 本机没有 Apple Development 或其他有效代码签名身份时会退回 ad-hoc 签名;这种签名每次代码变化都可能让 macOS 重新要求辅助功能 / 完全磁盘访问授权。
- 首次 `open /Applications/AgentPet.app` 启动会幂等把 `cc` / `cx` 命令简写写进 `~/.zshrc`(`claude` / `codex` 放飞版,跳过确认)——换台电脑装上桌宠就自带 `cc` / `cx`,新开终端即用;已有同名 alias 原样跳过、绝不改动。`cc` 是系统 C 编译器的标准名,故只做 shell alias、不装成 PATH 可执行,以免遮蔽 `/usr/bin/cc` 害了 `make` / `./configure`。
- 刻意用 Swift 5 模式编译以规避严格并发误报。
- 后台附件应用(`LSUIElement`):不占 Dock、不抢焦点,窗口浮于所有桌面/全屏之上。

---

## 命令行自测开关

不依赖屏幕、不触碰隐私,改动后据此本地核对:

```bash
BIN=./AgentPet.app/Contents/MacOS/AgentPet

# 外观(渲染一帧 PNG 肉眼核对)
"$BIN" --render-test  [out.png] [light|dark]   # 常态星芒(可选亮/暗底核对描边)
"$BIN" --render-eat   [out.png]                # 张嘴进食
"$BIN" --render-look  [out.png] [dx] [dy]      # 眼神方向
"$BIN" --render-blink [out.png]                # 闭眼(眨眼/哈欠)
"$BIN" --render-happy [out.png]                # 眯眼笑
"$BIN" --render-run   [out.png] [1|2]          # 跑步腿
"$BIN" --render-badge [out.png] [running] [waiting] # 会话角标

# 投喂 / 翻译 / 通知(打印结果,不真正执行)
"$BIN" --feed-dryrun  <路径> [claude|codex]    # 文件投喂脚本(核对路径转义)
"$BIN" --ask-dryrun   <文本> [claude|codex]    # 文字投喂脚本(核对家目录与 prompt 转义)
"$BIN" --translate-dryrun <文本>               # 翻译指令与真翻一次
"$BIN" --notify-dryrun [agentpet://...]       # 陪跑/报喜 URL 解析与横幅文案(含 tty 与回现场去向)
"$BIN" --telegram-token-list-dryrun <文本>     # 远程遥控:离线核对多 bot token 字段拆分/去重(脱敏打印)
"$BIN" --telegram-dryrun <claude|codex> <文本> # 远程遥控:离线打印将执行的 cc/cx 命令(首轮+续接),不连网
"$BIN" --telegram-stream-dryrun <claude|codex>  # 远程遥控:离线喂样本核对流式进度提取(进度行/最终正文/会话 id),不连网
"$BIN" --telegram-file-task-dryrun             # 远程遥控:离线核对 Telegram 文件任务目录隔离/meta/outbox
"$BIN" --telegram-file-cleanup-dryrun          # 远程遥控:离线核对文件任务清理(按天保留/容量删最旧/空壳回收)+ 目录迁移/日期分桶拍平/meta 洗白,不碰真实文件
"$BIN" --telegram-live-test <claude|codex> <文本> # 远程遥控:真跑一轮打印实时进度(会真调 CLI、耗额度)
"$BIN" --feishu-pb-test                          # 远程遥控(飞书):长连接 protobuf 帧编解码往返自测,不连网
"$BIN" --feishu-event-dryrun                     # 远程遥控(飞书):样本事件解析自测(私聊/群@/非文字),不连网
"$BIN" --bot-setup-dryrun                        # 远程 Bot 个性化设置状态机自测,不连网、不碰真实配置
"$BIN" --announcement-dryrun                     # 远程新功能公告待推送目标检查,不发送、不打印 token
"$BIN" --focus-tty <tty>                        # 按 tty 实跑回到对应终端窗口(真切窗口)

# 权限 / 探测排查
"$BIN" --permissions-dryrun      # 打印完全磁盘访问 / 辅助功能的探测状态
"$BIN" --install-aliases-dryrun  # 打印 cc/cx 写入 ~/.zshrc 的判定与将追加内容(只读不写)
"$BIN" --install-aliases-selftest # cc/cx 写入逻辑离线自测(临时文件真写入,核对幂等/已有各场景)
"$BIN" --finder-selection        # 打印 Finder 当前选中项(首次触发自动化授权)
"$BIN" --wechat-detect-dryrun    # 打印微信未读探测状态
```

> 呼吸、跳、悬停、横幅点击、会话角标、双击弹框等运行时动画离屏快照测不到,只能实跑观感。
