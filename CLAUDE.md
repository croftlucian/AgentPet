# CLAUDE.md

本文件给后续在本仓库工作的 Claude Code / Codex 提供项目约定、架构入口和验证方式。当前代码状态以 `Sources/main.swift` 为准。

## 项目定位

macOS 桌面宠物：在屏幕角落浮一个手绘的 Claude 星芒，安静呼吸；支持拖文件、全局快捷键、剪贴板、双击输入，把内容投喂给 Claude / Codex；同时陪跑 Claude Code / Codex 生命周期、提示微信/飞书未读、划词翻译和作息提醒；还能经 Telegram / 飞书远程遥控 cc/cx，并把远程每轮任务落盘成 JSONL、起本地仪表盘监控。核心运行逻辑在 `Sources/main.swift`（约 3690 行，AppKit），另有三个独立模块：`Sources/RemoteControl.swift`（Telegram 远程遥控，约 834 行）、`Sources/FeishuRemote.swift`（飞书长连接远程遥控，约 766 行）、`Sources/TaskMonitor.swift`（任务监控落盘 + 本地 HTTP 仪表盘，约 417 行），四文件由 `build.sh` 一起 `swiftc` 编进同一二进制。无 Xcode 工程、无 SwiftPM，构建完全由 `build.sh` 驱动。

## 构建与运行

```bash
./build.sh                 # swiftc 编译 + 组装 .app + 写 Info.plist + 签名
open ClaudePet.app         # 启动桌宠
```

构建用 `swiftc -swift-version 5 -O` 并显式链接 `AppKit`：刻意锁定 Swift 5 模式以规避严格并发误报。改动并发、actor、入口初始化相关代码时必须保持这一约束，不要擅自升级到 Swift 6 模式。

`build.sh` 还会写入 `Info.plist`、登记 `claudepet://` URL 协议，并在 `ClaudePet.app/Contents/Resources/` 下生成 `cc` / `cx` 包装命令：投喂优先走这些包装命令，再回退到系统里的 `claude` / `codex`。

## 验证

可执行文件内置若干本地自测开关，不依赖屏幕、不读取桌面内容，是改动渲染、投喂、翻译和通知逻辑后的标准核对方式：

```bash
BIN=./ClaudePet.app/Contents/MacOS/ClaudePet

"$BIN" --render-test  [out.png] [light|dark]   # 常态星芒，可选亮/暗底核对描边
"$BIN" --render-eat   [out.png]                # 张嘴进食
"$BIN" --render-look  [out.png] [dx] [dy]      # 眼神方向
"$BIN" --render-blink [out.png]                # 闭眼
"$BIN" --render-happy [out.png]                # 眯眼笑
"$BIN" --render-run   [out.png] [1|2]          # 跑步腿
"$BIN" --render-badge [out.png] [running] [waiting] # 会话角标

"$BIN" --feed-dryrun  <路径> [claude|codex]    # 文件投喂脚本
"$BIN" --ask-dryrun   <文本> [claude|codex]    # 文本投喂脚本
"$BIN" --translate-dryrun <文本>               # 翻译 prompt 与真实调用
"$BIN" --notify-dryrun [claudepet://...]       # 陪跑 URL 解析与横幅文案(含 tty 与回现场去向)
"$BIN" --focus-tty <tty>                        # 按 tty 实跑回到对应终端窗口(真切窗口,核对定位脚本)

"$BIN" --finder-selection        # Finder 当前选中项，首次会触发自动化授权
"$BIN" --wechat-detect-dryrun    # 微信未读探测状态
"$BIN" --wechat-dump             # 临时诊断:把 Dock 与微信辅助功能树真实字段 dump 到 /tmp/claudepet.log(命令行未授权则空,定准规则后连同菜单项一并移除)
"$BIN" --telegram-dryrun <claude|codex> <文本>  # 远程遥控:离线打印将执行的 cc/cx 命令(首轮+续接),不连网
"$BIN" --telegram-stream-dryrun <claude|codex>  # 远程遥控:离线喂样本 JSONL,核对流式进度提取(进度行/最终正文/会话 id),不连网
"$BIN" --telegram-live-test <claude|codex> <文本> # 远程遥控:真跑一轮打印实时进度(会真调 CLI、消耗额度),核对流式读不死锁
"$BIN" --feishu-pb-test                          # 远程遥控(飞书):长连接 protobuf 帧编解码往返(数据帧字段无损 + ping 帧字节),不连网
"$BIN" --feishu-event-dryrun                     # 远程遥控(飞书):离线喂样本 im.message.receive_v1,核对解析(open_id/chat 类型/@剥离/文本),不连网
"$BIN" --permissions-dryrun      # 打印完全磁盘访问 / 辅助功能的探测状态(裸 CLI 与 .app 的 TCC 身份不同,仅核检测逻辑)
```

改星芒、眼形、腿部、角标时用渲染快照出 PNG；改投喂时用 `--feed-dryrun` / `--ask-dryrun` 核对 shell 转义；改陪跑协议时用 `hooks/claudepet-notify.sh` 的 `CLAUDEPET_NOTIFY_DRYRUN=1` 和 `--notify-dryrun` 双向核对。呼吸、跳、悬停、横幅点击、双击弹框、会话角标实时刷新等运行时动画离屏快照测不到，只能实跑观感。

## 架构要点

- **星芒自绘，不加载图片**：`PetView.starArt` 保存终端块元素拼图，`quadrants(of:)` 映射到 2×2 象限，`starImage(...)` 逐格填充。主色填充前先沿 8 个方向画高对比描边，保证深浅桌面上都能看清。
- **单一外观状态 + 按需重绘**：`mouthOpen`、`eyeLook`、`eyeMode`、`runPhase` 是核心外观状态。咀嚼、眨眼、哈欠、东张西望、跑步腿都只改状态并调用 `render()`，运行时由 `iconLayer` 显示，不把业务逻辑塞进 `draw(_:)`。
- **图层动画与定时切帧分离**：呼吸、跳、摇晃、哈欠用 Core Animation 的不同 `transform` keyPath 叠加；咀嚼、跑步腿、滑行用 `.common` RunLoop timer，保证拖拽和事件跟踪期间仍能动。
- **横幅统一出口**：微信、飞书、陪跑等待、任务完成、久坐、翻译提示都走 `bannerLayer` / `bannerTextLayer` / `flashNotice(...)`。`Settings.petDoNotDisturb` 会静音被动提示，主动触发的翻译和测试入口传 `force: true` 绕过。
- **陪跑状态按会话聚合**：`activeSessions` 以 `sid` 聚合多终端会话，`SessionInfo.waiting` 区分“跑”和“等”。`start` 进入跑态，`waiting` 仅在已有会话上改等态，`done` 移除会话；`updateSessionBadge()` 画“跑N / 等N / 跑N 等N”角标。**会话清理以进程存活为准**：hook 注入承载会话的 `claude`/`codex` 进程 `pid`，`SessionInfo.pid` 记之，`sweepStaleSessions()`（15s 一轮）对有 pid 的会话 `kill(pid, 0)` 探活——进程退出（硬退出/崩溃/被杀/关终端，这些都来不及发收工钩子）即清角标、不干等超时；进程在则保留（不受时限，顺带根治长任务无中间事件被 600s 误清），30 分钟硬上限兜 pid 复用与僵死；老 hook 不带 pid 时退回纯 10 分钟超时兜底。**坑**：hook 每个事件都是 `open claudepet://` 一发即走，LaunchServices **不保证按发出顺序投递**，而 `sid` 在整段对话里复用——上一轮迟到的 `done` 会误删刚开跑的新轮（「跑」丢）、上一轮迟到的尾随 `waiting`（收工后的“闲等输入”）会把新轮误标「等」。故 hook 给每个事件注入生成时间戳 `ts`，`handleCompanionEvent` 按 `ts` 定序（`lastEventAt[sid]`）：同一 `sid` 收到比已处理更旧的事件一律丢弃，一并治住「跑」「等」两类错标。改会话状态机时别把这层去掉；老 hook 不带 `ts` 时退化为不去重，功能不哑火。
- **横幅可回现场**：`showBanner(..., actionCwd:, actionTty:)` 记录目录与终端 `tty`，点击横幅时 `returnToScene(cwd:tty:)` 优先按 `tty` 用 AppleScript 精确 `focus` 到承载该会话的那一个终端窗口（`focusTerminalSurface` 分别针对 Ghostty / iTerm2 / Terminal.app，只查在跑的终端、命中即止）；多终端并发时光靠 `cwd` 区分不出（常都在同一仓库目录），必须靠 `tty`。tty 缺失/窗口已关/无对应终端在跑时退回 `activateAnyTerminalOrOpen(cwd:)`——整窗唤前台，没终端则 Finder 打开目录。osascript 起子进程放后台跑，避免点一下卡住桌宠。
- **设置集中在 `Settings`**：所有用户偏好走 `UserDefaults`，布尔/整数/字符串各有 `boolValue` / `intValue` / `stringValue(_:default:)` 助手，避免未设置时误读为 `false` / `0`。`Settings` 是 internal（非 private）——远程遥控模块需跨文件读写它。设置项包括划词翻译、免打扰、会话角标、陪跑开关、作息提醒、停靠角、IM 通知、远程遥控（总开关 + cc/cx 两个 bot token + chat id 白名单）。
- **设置窗口是手写 AppKit 布局**：`SettingsWindowController` 维护权限、划词翻译、互动、陪跑、作息脾气、通知、窗口七组控件。改设置项时要同步 `buildContent(...)`、对应 action、回填方法和必要通知。新增组靠顶部加高窗口(`content` 高度)腾出空间、不挪动既有控件 y 坐标。
- **权限组只读状态 + 跳转**：app 无法给自己授权,「权限」组只显示完全磁盘访问(探测 `~/Library/Application Support/com.apple.TCC/TCC.db` 是否可读,见 `PetView.hasFullDiskAccess`)、辅助功能(`AXIsProcessTrusted`)的状态,并用 `x-apple.systempreferences:...?Privacy_AllFiles|Privacy_Accessibility` 一键跳到系统设置;`windowDidBecomeKey` 在切回窗口时重新探测刷新。完全磁盘访问是远程遥控 cc/cx 进受保护目录的关键(子进程继承桌宠的 TCC 授权)。
- **IM 未读只看提示面**：`imTargets` 泛化微信/飞书，默认关闭；轮询 Dock 辅助功能树和窗口标题，判断是否有未读和粗略数量，不读取数据库和消息正文。
- **投喂入口归一**：拖放、`⌥⌘C`、`⌥⌘X`、`⌥⌘V`、双击/菜单输入最终都进入 `PetView.analyze(...)` 或 `PetView.analyzeText(...)`，由 `FeedTool` 决定 Claude / Codex 命令候选和 prompt 文案。
- **全局热键中心化分发**：`GlobalHotKey` 只安装一个 Carbon application handler，用 keyCode 作为 hotKeyID 查表分发。不要给每个热键各装一个 handler，否则事件链可能被先返回 `noErr` 的处理器吃掉。
- **通知协议入口在 AppDelegate**：`AppDelegate.application(_:open:)` 接收 `claudepet://start|waiting|done?...`，`handleClaudePetURL(_:)` 解析 `tool`、`sid`、`cwd`、`task`，节流只抑制横幅，不抑制会话状态和角标更新。
- **远程遥控独立成模块**：`Sources/RemoteControl.swift` 接 Telegram。`TelegramBot` long polling 收消息当 prompt 喂给 `AgentRunner`（非交互跑 cc/cx，自带跳过权限确认参数；claude 走 `-p … --output-format stream-json --verbose [--resume sid]`，codex 走 `exec [resume sid] … --json --dangerously-bypass-approvals-and-sandbox -C cwd -o lastFile`），回话回传聊天；cc/cx 各占一个独立 bot、各维持一条可续接会话，聊天里 `/cd`、`/pwd`、`/new`、`/help` 控目录与上下文。`RemoteControl.shared.reload()` 按 `Settings.remoteEnabled` + token 起停 bot；配置走 `RemoteControlWindowController` 独立小窗（右键「远程遥控(Telegram)…」进）。本模块**不直接持有 `PetView`**：远程收到/答完经 `onActivity` 闭包（AppDelegate 注入）回桌宠 `remoteActivity(...)` 闪横幅，故改桌宠外观无需动这里。chat id 白名单挡陌生人；token 只落 `UserDefaults`、不入仓库。
- **远程遥控带实时进度**：两端 CLI 都按行吐 JSONL（claude `stream-json` 必须配 `--verbose`、codex `--json`），`AgentRunner.run` 边读 `stdout` 边 `parseStreamLine` 解析，经 `onProgress` 把每个关键步骤（claude 的 text/tool_use、codex 的 command_execution/agent_message）实时回调；`streamLines` 逐行读管线 + 「读取线程/进程退出」双信号量做超时守护，terminate 即 EOF 收尾、不死锁。`runAgent` 先发占位消息，再用 `ProgressPanel`（尾部窗口 + 时间节流，默认 1.8s / 12 行）`editMessageText` 原地刷新它，最终正文另发一条——治“发出去石沉大海、看不到进度”。会话 id：claude 取 `result.session_id`，codex 取 `thread.started.thread_id`（旧 `extractCodexSessionID` 找的 `thread.id` 在 codex 0.140.0 抓不到、每轮误开新会话，已废弃换实测字段）。**坑**：Telegram 同 chat 编辑过频会 429，`ProgressPanel` 节流别去掉；内容未变时 Telegram 回 400，无害忽略。`stdout` 流式读、`stderr` 仍进程结束后一次性读（正常两端错误都走 stdout）。
- **飞书远程遥控同构复用**：`Sources/FeishuRemote.swift` 接飞书，与 Telegram 同构——传输无关的 `AgentRunner` / `ProgressPanel` / `ChatContext` / `AgentReply` 整体复用，只换“收/发/编辑消息”这一层。收消息走飞书**事件订阅—长连接（WebSocket）**：纯出站、免公网回调，和 Telegram long polling 对称。`FeishuLongConn` 先 `POST /callback/ws/endpoint`（带 AppID/AppSecret）拿 wss 地址与 `ClientConfig`，再用 `URLSessionWebSocketTask` 收发 **protobuf 帧**（`FeishuFrame`，字段/tag 对齐官方 `oapi-sdk-go` 的 `pbbp2.Frame`；`Protobuf` 是纯 Swift 手写的最小 varint + 变长字节编解码，零依赖，只认 wire type 0/2）；按 `PingInterval` 主动发 control ping；收 `method=Data` 事件帧先按 headers `sum/seq` 合包，再回 `{"code":200}` 回执——**不回执飞书会按 15s/5m/1h/6h 重推**。`FeishuBot` 解析 `im.message.receive_v1`：`event_id` 幂等去重、发送者 `open_id` 白名单、私聊直接答群里需 @机器人（靠 `mentions` 判断并剥离 `@_user_N`）、回信私聊用 `open_id` 群用 `chat_id`。cc/cx 各对应一个企业自建应用（各 app_id+app_secret），与 Telegram 共用 `Settings.remoteEnabled`，由 `RemoteControl.reload()` 统一起停。**坑**：飞书 Frame 是 proto2，`SeqID/LogID/service/method` 手写编码须无条件写（含 0 值）否则解码端判缺失；飞书单条消息可编辑次数有限，`ProgressPanel`（飞书侧节流放宽到 3s）刷到上限即停、最终正文照样另发；**仅国内版 open.feishu.cn 支持长连接，国际版 Lark 只能 webhook**。改桌宠外观不必动这里（同 Telegram，经 `onActivity` 闪横幅）。离线自测：`--feishu-pb-test`（帧往返）、`--feishu-event-dryrun`（事件解析）。
- **任务监控独立成模块**：`Sources/TaskMonitor.swift` 把远程遥控（Telegram / 飞书）每轮“问题→答案”连同发起人、墙钟时长、CLI 自报花费/token 落盘成 JSONL（`~/Library/Application Support/com.claude.pet/monitor/tasks.jsonl`），并用系统自带 `Network`（`NWListener`，零三方依赖、只听 127.0.0.1）起本地 HTTP 服务暴露 `/api/tasks`、`/api/stats`，同时托管兄弟项目 `../claude-pet-monitor/dist`（前端仪表盘）；dist 缺失时回退到内置单文件页面，保证开关一开即用、不强依赖 Node 构建。计量来自 `AgentRunner` 在 claude `result` 事件里解析出的 `duration_ms`/`total_cost_usd`/`usage`（新增 `AgentReply.metrics`/`status` 与 `StreamEvent.metrics`；codex 无此字段留 nil，墙钟时长由调用方在 Telegram/飞书的 `runAgent` 两处统一测量并调 `TaskMonitor.record`）。设置开关在主设置窗顶部“任务监控”组（`Settings.monitorEnabled`/`monitorPort`/`monitorPluginPath`），`TaskMonitor.reload()` 按开关起停服务、`AppDelegate` 启动时调一次。本地投喂(拖放/快捷键/双击)交给终端、进程内拿不到答案与发起人,故不记录,只覆盖远程两条链路。

## 快捷键与入口

| 入口 | 行为 |
| --- | --- |
| 拖文件/目录到桌宠 | 喂给 Claude |
| `⌥⌘C` | Finder 当前选中项喂给 Claude |
| `⌥⌘X` | Finder 当前选中项喂给 Codex |
| `⌥⌘V` | 剪贴板文本喂给 Claude |
| `⌥⌘T` | 翻译当前选中文字，结果显示在横幅 |
| 单击身体 | 嚼一口 |
| 双击身体 | 弹输入框，默认问 Claude |
| 右键菜单 | 设置、远程遥控(Telegram / 飞书)、问 Claude/Codex、使用说明、测试提示、导出诊断、退出 |
| 点击带目录的横幅 | 回到终端或目录现场 |

## 陪跑 hook

陪跑靠 `hooks/claudepet-notify.sh` 把 Claude Code / Codex 的事件转成 `claudepet://` URL。

- Claude Code：`UserPromptSubmit` 接 `claude start`，`Notification` 接 `claude waiting`，`Stop` 接 `claude done`，事件 JSON 从 stdin 读。
- **`StopFailure` 也必须接 `claude done`**：`Stop` 只在正常答完时触发，网络/接口报错、重试耗尽那轮走的是 `StopFailure`(Claude Code 2.1.78+)。少挂它，报错那轮收不到收工事件，会话会一直占着角标「跑 N」直到 10 分钟超时兜底才清——这正是“网络重试后角标卡住不结束”的根因。脚本按 argv 第二参定相位，`done` 已能复用，无需改脚本，只补 hook 注册即可。注：`StopFailure` 只兜"应用内失败钩子还发得出"那一类；客户端进程被强杀/崩溃/超时硬退出、连钩子都来不及发时，由会话进程 `pid` 的 `kill(0)` 探活兜底（见上"陪跑状态按会话聚合"）。
- Codex 新式 hooks：`UserPromptSubmit` / `PermissionRequest` / `Stop` 分别接 `codex start` / `codex waiting` / `codex done`。
- Codex 旧式 `notify`：只兼容完成事件，脚本会过滤非 `agent-turn-complete`。
- `sid` 优先取事件里的 session 标识，拿不到时用 `tool|cwd` 兜底；`task` 会从 Codex `input-messages` 或 Claude transcript 中提取并压到 60 字。
- `tty` 由 `detect_tty` 沿父进程链上爬取第一个挂着真实 tty 的祖先（hook 自身 stdin 多是管道、读不到），规范成 `/dev/ttysXXX`，供桌宠点横幅时精确回到这一个终端窗口；拿不到则留空、桌宠退回整 App 唤前台。

注意：`Stop` / `agent-turn-complete` 表示“答完一轮”，不是整任务完成信号。

## 已知约定与坑

- 最低系统 macOS 13.0，`LSUIElement=true`，应用以 accessory 模式运行，不占 Dock。
- `PetView.log(_:)` 追加到 `/tmp/claudepet.log`，属于临时诊断手段；清理日志时要连同各 `Self.log(...)` 调用一起看。
- `Resources/claude-icon.png` 不参与运行时渲染；星芒由代码绘制。
- `draw(_:)` 只服务 `--render-*` 离屏快照，运行时画面由图层显示。
- `cc` / `cx` 包装命令由 `build.sh` 写入 app resources；alias 在非交互脚本里不可用，所以不要把投喂链路改回依赖 shell alias。
- `--translate-dryrun` 会真实调用 Claude CLI；没有 CLI 或命令失败时会打印失败信息。
- README 是面向使用者的完整说明；本文件是面向开发者的架构和验证速查。两者涉及命令行自测、快捷键、hook 语义时需要同步更新。
