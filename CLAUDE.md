# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## 项目定位

macOS 桌面宠物：在屏幕右下角浮一个手绘的 Claude 星芒，安静呼吸；把文件/目录拖到它身上，它会"张嘴咀嚼"，随后在终端唤起 `claude` 交互会话来分析被投喂的文件。全部逻辑集中在单一源文件 `Sources/main.swift`（约 420 行，AppKit）。无 Xcode 工程、无 SwiftPM，构建完全由 `build.sh` 驱动。

## 构建与运行

```bash
./build.sh                 # swiftc 编译 + 组装 .app + 写 Info.plist + ad-hoc 签名
open ClaudePet.app         # 启动桌宠
```

构建用 `swiftc -swift-version 5 -O` 并显式链接 `AppKit`：**刻意锁定 Swift 5 模式**以规避严格并发的误报（本机装的是 Swift 6.2）。改动并发/actor 相关代码时务必保持这一约束，勿擅自升级到 Swift 6 模式。

## 验证(本项目唯一的自测手段)

可执行文件内置若干离屏自测开关，**不依赖屏幕、不触碰桌面隐私**，是改动渲染/投喂逻辑后的标准核对方式：

```bash
./ClaudePet.app/Contents/MacOS/ClaudePet --render-test  [out.png] [light|dark]   # 渲染常态星芒一帧;可选 light/dark 底色档,核对描边轮廓在亮/暗背景上的勾边
./ClaudePet.app/Contents/MacOS/ClaudePet --render-eat   [out.png]   # 渲染张嘴进食一帧,核对嘴的位置/大小
./ClaudePet.app/Contents/MacOS/ClaudePet --render-look  [out.png] [dx] [dy]   # 渲染原图两个空位偏移后的眼神方向
./ClaudePet.app/Contents/MacOS/ClaudePet --render-blink [out.png]   # 渲染闭眼一帧(眨眼/哈欠的眼形),核对水平细缝
./ClaudePet.app/Contents/MacOS/ClaudePet --render-happy [out.png]   # 渲染眯眼笑一帧(弯月眼),核对悬停笑脸
./ClaudePet.app/Contents/MacOS/ClaudePet --render-run   [out.png] [1|2]   # 渲染跑步腿一帧,核对扑食滑行时的腿部摆动
./ClaudePet.app/Contents/MacOS/ClaudePet --feed-dryrun <路径> [claude|codex]   # 打印投喂脚本(不执行),核对路径转义与命令拼装(默认 claude)
./ClaudePet.app/Contents/MacOS/ClaudePet --finder-selection        # 打印当前 Finder 选中项路径,核对快捷键投喂的"取文件"这步(首次触发自动化授权)
./ClaudePet.app/Contents/MacOS/ClaudePet --wechat-detect-dryrun    # 打印微信未读探测状态,排查辅助功能权限和微信版本差异
./ClaudePet.app/Contents/MacOS/ClaudePet --notify-dryrun [URL]     # 打印 claudepet:// 通知 URL 解析出的工具/目录与报喜文案(默认 claudepet://done?tool=claude)
```

改了星芒绘制/眼形/腿部 → 用 `--render-test`/`--render-eat`/`--render-look`/`--render-blink`/`--render-happy`/`--render-run` 出图肉眼核对；改了投喂逻辑 → 用 `--feed-dryrun` 核对 shell 转义。**注意**：呼吸/跳/摇晃/伸懒腰/悬停/空闲调度都是运行时动画,离屏快照测不到,只能实跑观感。

## 架构要点(读多个片段才看得出的"大局")

- **星芒靠象限自绘,不走字体**：`PetView.starArt` 是取自 Claude Code 欢迎界面的终端块元素字符拼图（`▐▛███▜▌` 等），`quadrants(of:)` 把每个块字符映射成 2×2 象限的填充开关，`starImage(size:mouthOpen:eyeLook:eyeMode:)` 据此逐格填矩形。因此没有字体拼接缝隙，能严丝合缝还原终端里的样子。要调整造型，改这三处。**填主色前先描一圈高对比轮廓**：`starImage` 内的 `fillStar` 闭包沿 8 个方向用 `outlineColor(for:)`（暗主色配近白边、亮主色配近黑暖边）"膨胀"填一遍,再用主色覆盖中心——不论桌面背景明暗、主色深浅都能把星芒形状勾出来,是"看不清"的核心兜底,不依赖任何背景采样或权限。

- **单一外观状态 + 按需重绘**：运行时不再预渲染多帧。`mouthOpen`/`eyeLook`/`eyeMode`(三个字段) 是唯一外观状态,任何动作改完状态后调 `render()` 即刻出一张 90pt 图送入 `iconLayer`。表情维度一多(嘴×眼神×眼形)预渲染组合会爆炸,单口径出图反而更省更清晰。咀嚼/眨眼/哈欠/东张西望都只是改这几个字段。

- **眼睛三态共用一条挖洞路子**(`moveBuiltInEyeHoles` 按 `eyeMode` 分支)：先铺橙补回原图两个深色空位,再挖出深色眼形——`normal`=竖洞(随鼠标 `eyeLook` 偏移)、`closed`=水平细缝(眨眼/哈欠)、`happy`=上凸弯月(眯眼笑)。细缝与弯月用 `CGContext` 的 `.clear` 混合模式描边清成透明,不是填矩形。没有新增眼睛素材,只是让原空位变形。

- **动画分两层,各走各的不打架**：
  - **图层动画**(Core Animation,自跑无需逐帧)：呼吸 `startBreathing(scaleLow:scaleHigh:)` 用 `transform.scale`(同 key 重加即替换,悬停时换 1.08~1.18 放大区间);开心跳 `jump()` 用 `transform.translation.y`;摇晃 `sway()` 用 `transform.rotation.z`;伸懒腰 `yawn()` 用 `transform.scale.y`。**关键**:这几个动作刻意挑 transform 的**不同 keyPath**,CA 会合成叠加,不会互相覆盖(尤其 `scale.y` 与呼吸的 `scale` 并存)。**这些动作只动图层 transform、绝不动窗口**——窗口一动鼠标相对位置就变,会反复触发 hover 进/出抖动。
  - **Timer 切帧**(改外观状态 + `render()`)：咀嚼在 `mouthOpen` 张/闭间切换；扑食滑行期间 `startRunningLegs()` 在 `runPhase` 1/2 间切换,只改原本底部两条腿,停下吃东西时 `stopRunningLegs()` 复位。**关键**:这些 Timer 必须加到 RunLoop 的 `.common` 模式——拖放进行中 runloop 处于 `eventTracking`,普通定时器与隐式动画都不触发,只有 `.common` 才能让它在拖拽期间动起来。

- **悬停/点击/空闲三套互动**：
  - 悬停 = `NSTrackingArea`(`.activeAlways` 让附件应用也收 hover)。`mouseEntered` → 眯眼笑 + 放大版呼吸 + 发光 + 跳一下;`mouseExited` 复位。
  - 点击 = `mouseUp` 触发 `eatBite()`(嚼一口);**刻意不 override `mouseDown`**,以保留 `isMovableByWindowBackground` 的整窗拖拽。
  - 空闲 = `scheduleIdle()`/`performRandomIdle()` 每隔 5~11s 随机挑(眨眼/东张西望/摇晃/哈欠);**但 hover/进食/扑食/眼睛被接管时一律 `return` 让路**,不打扰交互。东张西望与眨眼会置 `idleEyeActive`,`updateEyeLookFromMouse` 见此标志即让路,不与之抢眼神。

- **设置窗口与微信提示**：右键菜单的"设置..."由 `AppDelegate.showSettings(_:)` 打开 `SettingsWindowController`。目前可调扑食滑行速度、手动主色、自动适应环境色与微信通知提示:速度写入 `UserDefaults` 的 `pounceDuration`,范围 0.35~8.0 秒,默认 0.85 秒;手动颜色写入 `petColor`,默认 Claude 赤陶橙;自动适应写入 `autoAdaptColor`,默认开启;微信提示写入 `receiveWeChatNotifications`,默认关闭。自动配色模式不再走屏幕捕捉,也不需要屏幕录制权限；`PetView` 用 `.common` 模式 `Timer` 每 1.2 秒按系统深浅模式与系统强调色生成鲜艳醒目的运行时主色 `Style.currentPetColor`(色相跟随强调色、明度始终偏亮,不再掺前台 App 名字的随机 hash 以免颜色乱跳)。看清主要靠星芒描边轮廓兜底,这里只负责给一个好看且不撞背景的醒目色,且不会触碰屏幕内容；关闭自动后会立刻恢复手动颜色。微信提示模式下 `PetView` 每 2 秒先查微信/Dock 窗口标题,再通过辅助功能读取微信或 Dock 的未读提示文本,只判断是否有未读和粗略数量,不读取微信数据库、不解密、不保存聊天正文；检测到“无→有”或未读数量变化时让桌宠上方弹出“微信来消息了”横幅,同时跳一下、摇一下、短暂发光。右键菜单另有“测试微信提示”用于直接核对横幅观感。开启该项时系统会请求辅助功能权限,权限不足则只写一次 `/tmp/claudepet.log` 并保持静默；用 `--wechat-detect-dryrun` 可排查当前权限和命中来源。

- **任务完成通知(`claudepet://` 协议)**：Claude Code 跑完一轮(`Stop` 钩子)、Codex 跑完一轮(`notify`,仅 `agent-turn-complete` 事件算完成)各自 `open "claudepet://done?tool=<claude|codex>&cwd=<目录>"`。Info.plist 的 `CFBundleURLTypes` 声明了 `claudepet` 协议,系统把 GetURL 事件转给 `AppDelegate.application(_:open:)` → `handleClaudePetURL`,解析 `tool`/`cwd` 经纯函数 `taskDoneMessage(tool:cwd:)` 拼出"Claude 收工:<目录名>"之类文案,调 `showTaskDoneHint`。**报喜横幅与微信未读横幅是同一套**(`bannerLayer` + `flashNotice`,边框色按通知类型橙/绿区分),不是新控件——这也是把 `weChatBanner*` 正名为 `banner*`、把庆祝动作抽成 `flashNotice` 的缘由。两个 CLI 的事件差异(Claude 走 stdin、Codex 走 argv[1])都在仓库内 `hooks/claudepet-notify.sh` 里抹平;桌宠只读 URL 参数、只弹横幅,**绝不碰文件**。`--notify-dryrun <URL>` 离线核对解析与文案。设置窗口有「任务完成提示」开关(`Settings.receiveTaskDoneNotifications`,**默认开**,与微信/飞书开关并列;关掉后 `handleClaudePetURL` 收到 URL 直接忽略、不弹)。**注意 `Stop`/`agent-turn-complete` 是"每答完一轮就触发"、并非整任务完成**(Claude Code/Codex 无"整任务完成"信号),故文案表"答完了,该主公了"而非"收工";`handleClaudePetURL` 另设 8s 节流(同"工具+目录"窗口内只弹一次,`lastTaskDoneAt`),防连答多轮时连珠炮。横幅显示「客户端 · 任务」,任务来源:Codex 取 `input-messages`、Claude 顺 `transcript_path` 扒最近一条主公文本输入(都由 `hooks/claudepet-notify.sh` 用 python3 提取、`task=` 进 URL);横幅**高度自适应**(`showBanner` 按文本在固定宽度下测高换行,上限 `Style.bannerMaxHeight`),且 hover 跟踪区收窄到星芒身上(`petFrameInBounds`,去掉 `.inVisibleRect`)——免得为容纳横幅而加大的透明窗到处一碰就笑。

- **`draw(_:)` 只服务离屏快照**：运行时画面由 `iconLayer` 图层显示;`draw(_:)` 仅在 `--render-*` 自测路径被调用。别把运行时逻辑塞进 `draw(_:)`。

- **投喂入口殊途同归到 `analyze(_:with:)`**：① 拖文件到宠物身上(走 claude)；② 全局快捷键 **⌥⌘C → claude**、**⌥⌘X → cx**，取 **Finder 当前选中项**。`FeedTool` 枚举封装"用哪个 CLI"（命令候选 + 兜底路径），两个键只是 tool 不同、其余完全共用。快捷键路径经 `finderSelectionPaths()` 走 osascript 拿选中路径（首次触发"控制 Finder"自动化授权），再 `pounceToMouseAndEat()` 让桌宠**滑行到鼠标光标处**（`NSEvent.mouseLocation` 定位 + `slideWindow()` 用 `.common` 模式 Timer 逐帧 `setFrameOrigin` 移窗，**刻意不用 `NSWindow.animator()` 隐式动画——它对 borderless 窗口不产生可见位移**）张嘴"嚼一口"后滑回原位；**整段扑食(滑过去→嚼→滑回)跑完才唤起终端,否则终端立刻弹出会盖住滑行**（`pounceToMouseAndEat(then:)` 的收尾回调）。**只读取路径、绝不删改文件**——"吃"纯属动画 + 触发分析,文件留在原位。

- **全局热键中心化分发**：`GlobalHotKey`（enum）只装**一个** application 级 Carbon 事件处理器，按事件携带的 `hotKeyID`（拿 keyCode 当 id）查表派发到对应回调。**切勿给每个热键各装一个 handler**——Carbon 事件传播链里先返回 `noErr` 者会吃掉事件，另一个键就哑了。后台附件应用即可全局生效、免辅助功能权限；app 退出由系统回收热键，无需手动注销。

- **终端唤起链路**：拿到 URL → 生成临时 `claudepet-feed-<uuid>.command` 脚本（`feedScript(for:tool:)`，`cd` 到目标目录后按命令候选定位 tool 命令，再查 Homebrew 常见绝对路径，最后预填"分析这个文件/目录"）→ 优先 `ghostty -e <脚本>` 起新窗口，Ghostty 不在则回退 `NSWorkspace.open`（系统默认终端）。脚本承载命令是为了免额外权限。`shellQuoted(_:)` 负责单引号转义，是路径含空格/特殊字符时的唯一防线。

- **后台附件应用**：`LSUIElement=true` + `setActivationPolicy(.accessory)`，不占 Dock、不抢焦点；窗口 borderless、透明、`.floating` 层级、`canJoinAllSpaces`，所以跨所有桌面/全屏之上都可见。

- **入口并发处理**：程序启动即在主线程，顶层用 `MainActor.assumeIsolated { ... }` 安全进入主 actor 上下文后再解析参数、起 `NSApplication`。

## 已知约定与坑

- `Resources/claude-icon.png` **运行时并不加载**——星芒是纯代码绘制的，该 PNG 仅作参考图存放，别误以为是图标资源。
- `PetView.log(_:)` 向 `/tmp/claudepet.log` 追加诊断日志，源码注明是**临时**手段；清理时连同各 `Self.log(...)` 调用一并移除。
- 投喂功能依赖 `claude`（⌥⌘C / 拖放）或 `cx`（⌥⌘X）CLI 在 PATH 上；脚本会兜底检查 `/opt/homebrew/bin/` 与 `/usr/local/bin/` 的常见安装路径。Ghostty 为可选增强，缺失不影响。
- 最低系统 macOS 13.0（`LSMinimumSystemVersion`）。
- 调外观参数集中在文件顶部的 `Style` 枚举（主色、呼吸周期、窗口边长），优先改这里而非散落的字面量。
- 任务完成通知靠 `claudepet://` 协议唤起,需把 `hooks/claudepet-notify.sh`(已 `chmod +x`)接进两处**用户级**配置才生效:Claude Code 在 `~/.claude/settings.json` 的 `Stop` 钩子 `command` 填 `<绝对路径>/claudepet-notify.sh claude`;Codex 在 `~/.codex/config.toml`(`notify` 须置于所有 `[表]` 之前,且只认用户级、忽略项目级)填 `notify = ["<绝对路径>/claudepet-notify.sh", "codex"]`。桌宠须在运行中;首次 `open ClaudePet.app` 后 LaunchServices 才登记该协议。`CLAUDEPET_NOTIFY_DRYRUN=1` 跑脚本只打印 URL、不真正唤起,便于核对。
