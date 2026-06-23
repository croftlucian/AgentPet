# 远程遥控使用说明

这份说明面向已经构建并启动 ClaudePet 的使用者，讲清楚 Telegram 和飞书远程遥控怎么启用、聊天里每个命令怎么用，以及本地自测命令怎么排查。

远程遥控的执行层在本机跑 Claude CLI 或 Codex CLI：`cc` 对应 Claude，`cx` 对应 Codex。Telegram 和飞书只是收发消息；真正干活的是当前 Mac 上的 CLI，所以本机要先能正常运行 `claude` 或 `codex`。

## 一、启用前准备

1. 构建并启动桌宠。

```bash
./build.sh
open ClaudePet.app
```

2. 确认本机 CLI 可用。

```bash
claude --version
codex --version
```

3. 右键桌宠，打开「远程遥控(Telegram / 飞书)…」。
4. 勾选「启用远程遥控(Telegram / 飞书 共用总开关)」。
5. 按下面的 Telegram 或飞书步骤填凭证，点「保存并应用」。

说明：

- Telegram 和飞书共用一个总开关。
- cc 与 cx 各自独立配置；Telegram 每组可填多枚 token，某一组凭证留空时，该类 bot 或应用不会启动。
- 新会话默认工作目录是当前用户家目录。
- 远程任务会跳过 CLI 权限确认，等同把手机消息交给本机 `cc` / `cx` 执行；只把白名单给自己可信的账号。

## 二、Telegram 配置

Telegram 的 Claude(cc) 和 Codex(cx) 各是一组 bot token。每组都可以填多枚 token，适合“每个人一个独立 bot”。只想用其中一个工具，也可以只填对应工具的 token。

### 1. 创建 bot

1. 在 Telegram 找 `@BotFather`。
2. 给每个需要 Claude(cc) 的人创建一个 bot，保存 token，填到「Claude(cc)bot tokens(可多枚)」。
3. 给每个需要 Codex(cx) 的人创建一个 bot，保存 token，填到「Codex(cx)bot tokens(可多枚)」。
4. 多枚 token 用逗号、空格或换行分隔。

示例：

```text
111111:AAA...
222222:BBB...
333333:CCC...
```

### 2. 获取 chat id

1. 先让对应的人给自己的专属 bot 发一条任意消息，例如 `/help`。
2. 在浏览器打开：

```text
https://api.telegram.org/bot<你的 token>/getUpdates
```

3. 在返回 JSON 里找 `message.chat.id`。
4. 把这个 id 填到「允许的 chat id」，多个 id 用逗号、空格或换行分隔。

示例：

```text
123456789
123456789, -1001234567890
```

留空表示不限制来源，代码会放行所有能给 bot 发消息的人；日常使用不要留空。

### 3. 使用入口

- 给某个 Claude bot 发消息：本机跑 Claude(cc)。
- 给某个 Codex bot 发消息：本机跑 Codex(cx)。
- 每个 bot、每个 chat 都有独立工作目录和会话上下文。
- 多枚 token 会启动多个 Telegram 轮询器；日志里会显示 `cc/claude#1`、`cc/claude#2` 或 `cx/codex#1` 这类编号。

### 4. Telegram 文件消息

Telegram 可以直接发送文件给 bot，支持 `document`、`photo`、`video`、`audio`、`voice`、`animation`、`sticker`、`video_note`。图片会自动取最大尺寸那一份。

每条文件消息都会创建一个独立任务目录：

```text
~/ClaudePetRemoteFiles/<platform>/<bot>/<remoteUserID>/<yyyy>/<MM>/<dd>/<taskID>/
```

实际 Telegram 目录示例：

```text
~/ClaudePetRemoteFiles/telegram/cx-bot2/8231781034/2026/06/22/20260622-213015-a8f3/
```

每个任务目录固定包含：

```text
inbox/    # 当前消息上传的原始文件
work/     # 中间处理文件
outbox/   # 需要自动回传 Telegram 的最终文件
meta.json # 来源、用户、bot、文件、时间和路径记录
```

使用规则：

- 文件名会先清洗，`../`、绝对路径、隐藏路径前缀都不会保留为可跳出目录的路径。
- agent 处理文件任务时，运行目录会切到当前任务根目录。
- 原始文件只写入当前任务 `inbox/`。
- 需要传回 Telegram 的结果必须放进当前任务 `outbox/`。
- 执行结束后只扫描当前任务 `outbox/` 的普通文件并回传，不支持 `/send 任意路径`。
- 不同 bot、不同 Telegram 用户、不同任务日期和 `taskID` 都是不同目录，不会互相覆盖。
- 同一用户在同一个 bot 里上传过文件后，后续直接说“继续改刚才那个文件”“把上一个文档再整理一下”“把刚才的视频再压缩一下”，会自动续接最近一次文件任务，不需要重复上传。

发送方式：

```text
把 report.pdf 发给 bot，caption 写：提取里面的表格，整理成 CSV 发回来
```

如果只发文件、不写 caption，bot 会先保存文件，然后让 agent 回复已收到哪些文件并请你补充处理要求。

## 三、飞书配置

飞书只支持国内版 `open.feishu.cn` 的长连接方式。每个工具需要一个企业自建应用：一个给 Claude(cc)，一个给 Codex(cx)。

### 1. 创建应用

1. 到飞书开放平台创建企业自建应用。
2. 添加「机器人」能力。
3. 在权限管理里开通收发消息相关权限，例如 `im:message`。
4. 在「事件订阅」里选择「长连接」。
5. 订阅「接收消息 `im.message.receive_v1`」。
6. 发布应用版本，并让应用在企业内可用。

### 2. 填写凭证

在 ClaudePet 的远程遥控窗口里填写：

| 字段 | 用途 |
| --- | --- |
| `Claude(cc)App ID` | Claude 远程遥控应用的 App ID |
| `Claude(cc)App Secret` | Claude 远程遥控应用的 App Secret |
| `Codex(cx)App ID` | Codex 远程遥控应用的 App ID |
| `Codex(cx)App Secret` | Codex 远程遥控应用的 App Secret |
| `允许的 open_id` | 允许下发指令的飞书用户 open_id |

多个 `open_id` 可用逗号、空格或换行分隔。留空表示不限制来源，代码会放行所有能给应用发消息的人；日常使用不要留空。

### 3. 使用入口

- 私聊机器人：直接发文字消息即可执行。
- 群聊机器人：必须 @ 机器人，消息才会被处理。
- 非文字消息不会执行，机器人会回复「暂时只认文字消息。」。
- 私聊按发送者 open_id 维持会话；群聊按 chat_id 维持会话。

## 四、聊天命令总表

下面命令在 Telegram 和飞书里通用。普通文本不是斜杠命令时，会被当作 prompt 交给 cc/cx。

| 命令 | 用法 | 结果 | 示例 |
| --- | --- | --- | --- |
| 直接发消息 | 发任意非空文字 | 把这段文字作为 prompt 交给当前 bot 对应的 cc/cx | `帮我检查这个仓库的构建问题` |
| `/cd <路径>` | 切换工作目录 | 目录存在时切换 cwd，并自动开启新会话 | `/cd ~/work/my-repo` |
| `/pwd` | 查看当前目录 | 回复当前会话的工作目录 | `/pwd` |
| `/new` | 开新会话 | 清空当前 chat 的会话上下文，但保留当前工作目录 | `/new` |
| `/help` | 查看帮助 | 回复内置帮助和当前目录 | `/help` |
| `/start` | 查看帮助 | 行为同 `/help` | `/start` |

### 直接发消息

直接发文字时，当前 bot 会把消息当成 prompt：

```text
帮我看一下当前目录的 README 是否需要补使用说明
```

执行流程：

1. bot 先回复「收到，开跑」。
2. ClaudePet 在当前工作目录启动 Claude 或 Codex。
3. bot 原地刷新进度消息，展示读取文件、执行命令或中间回复。
4. 任务结束后，bot 另发最终答复。
5. 会话 id 会保存下来，下一条普通消息会续接同一上下文。

同一个 chat 上一条任务没结束时，再发普通消息会收到「上一条还在跑，等它答完再发哈。」。不同 chat 可以并行执行。

### `/cd <路径>`

切换当前 chat 的工作目录，并清空会话上下文。路径会按 macOS 规则展开 `~`。

```text
/cd ~/other-project/myself/ClaudePet
```

成功回复：

```text
已切到 /Users/你/other-project/myself/ClaudePet,并开了新会话。
```

失败场景：

- 没有写路径：回复 `目录不存在:(空)`。
- 路径不存在：回复 `目录不存在:<原始路径>`。
- 路径是文件而不是目录：同样按目录不存在处理。

使用建议：

- 每次切项目后先发 `/pwd` 核对。
- `/cd` 会自动开新会话，避免旧项目上下文串到新项目。
- 目录里如果需要访问受系统保护的位置，请先给 ClaudePet.app 对应的 macOS 权限。

### `/pwd`

查看当前 chat 的工作目录。

```text
/pwd
```

回复示例：

```text
当前目录:/Users/你/other-project/myself/ClaudePet
```

### `/new`

清空当前 chat 的会话上下文，保留当前工作目录。

```text
/new
```

适合这些场景：

- 想换一个任务，不希望沿用上一轮上下文。
- 上一轮回答方向跑偏，需要重新开始。
- 同一目录下连续处理多个互不相关的问题。

### `/help` 和 `/start`

查看 bot 内置帮助和当前目录。

```text
/help
/start
```

Telegram 和飞书都会列出 `/cd`、`/pwd`、`/new`、`/help`。飞书帮助会额外提示群里需要 @ 机器人。

## 五、cc 与 cx 的区别

| 入口 | 本机工具 | 远程执行方式 | 会话续接 |
| --- | --- | --- | --- |
| Claude bot / Claude 飞书应用 | Claude CLI | `claude -p ... --output-format stream-json --verbose --dangerously-skip-permissions` | 使用 Claude 返回的 `session_id` 和 `--resume` |
| Codex bot / Codex 飞书应用 | Codex CLI | `codex exec ... --json --dangerously-bypass-approvals-and-sandbox --skip-git-repo-check` | 使用 Codex 返回的 thread id 和 `exec resume` |

实际使用时，只要记住：

- 想让 Claude 干活，就发给 cc 对应的 bot 或应用。
- 想让 Codex 干活，就发给 cx 对应的 bot 或应用。
- 两边上下文互不共享。

## 六、本地自测命令

先构建：

```bash
./build.sh
BIN=./ClaudePet.app/Contents/MacOS/ClaudePet
```

### `--telegram-dryrun`

离线打印远程遥控实际会拼出的 CLI 参数，不联网、不启动 agent。

```bash
"$BIN" --telegram-dryrun claude "总结当前目录"
"$BIN" --telegram-dryrun codex "检查构建脚本"
```

用途：

- 核对 Claude/Codex 参数是否符合预期。
- 核对 prompt 转义。
- 同时能看到首轮命令和带示例 session id 的续接命令。

### `--telegram-token-list-dryrun`

离线验证多 bot token 字段如何拆分、去空和去重，只打印脱敏摘要。

```bash
"$BIN" --telegram-token-list-dryrun "111:AAA, 222:BBB 111:AAA"
```

用途：

- 核对多枚 token 的分隔方式。
- 确认重复 token 不会启动重复轮询器。
- 避免在日志里打印完整 token。

### `--telegram-stream-dryrun`

离线喂内置 JSONL 样本，验证流式进度解析。

```bash
"$BIN" --telegram-stream-dryrun claude
"$BIN" --telegram-stream-dryrun codex
```

用途：

- 检查进度行提取。
- 检查最终正文提取。
- 检查会话 id 提取。

### `--telegram-file-task-dryrun`

离线验证 Telegram 文件任务目录隔离、文件名清洗、`meta.json` 写入和 `outbox` 扫描，不联网。

```bash
"$BIN" --telegram-file-task-dryrun
```

用途：

- 核对任务目录形如 `~/ClaudePetRemoteFiles/telegram/<bot>/<remoteUserID>/<yyyy>/<MM>/<dd>/<taskID>/`。
- 确认原始文件只进入 `inbox/`，中间文件放 `work/`，最终回传文件只从 `outbox/` 读取。
- 确认危险文件名会被清洗，目录和隐藏路径不会逃出任务目录。

### `--telegram-live-test`

真跑一轮 CLI，并在终端打印实时进度。这个命令会调用 Claude 或 Codex，可能消耗额度。

```bash
"$BIN" --telegram-live-test claude "用一句话回复 OK"
"$BIN" --telegram-live-test codex "用一句话回复 OK"
```

用途：

- 验证本机 CLI 能被 ClaudePet 启动。
- 验证流式读取不会卡死。
- 验证最终正文和会话 id 能拿到。

### `--feishu-pb-test`

离线验证飞书长连接 protobuf 帧编解码，不联网。

```bash
"$BIN" --feishu-pb-test
```

用途：

- 验证数据帧字段往返无损。
- 验证 ping 控制帧字节符合当前实现预期。

### `--feishu-event-dryrun`

离线喂内置飞书事件样本，验证消息解析。

```bash
"$BIN" --feishu-event-dryrun
```

用途：

- 验证私聊消息解析。
- 验证群聊 @ 机器人时会剥离 mentions 标记。
- 验证非文字消息不会进入执行链路。

## 七、排查清单

### bot 没反应

1. 确认 ClaudePet.app 正在运行。
2. 确认远程遥控总开关已勾选，并点过「保存并应用」。
3. Telegram 检查 token 是否填到对应工具字段。
4. 飞书检查 App ID/App Secret 是否成对填写，应用是否发布，事件订阅是否为长连接。
5. 检查白名单是否包含当前 chat id 或 open_id。
6. 查看诊断日志：

```bash
tail -f /tmp/claudepet.log
```

### 能收到消息但执行失败

1. 在终端确认 `claude --version` 或 `codex --version` 能跑。
2. 用 `--telegram-live-test` 真跑一轮。
3. 用 `/pwd` 确认工作目录。
4. 用 `/cd <项目路径>` 切到真实项目目录。
5. 如果需要访问受保护目录，给 ClaudePet.app 配好 macOS 权限后重启应用。

### 飞书群聊不响应

1. 群里必须 @ 机器人。
2. 只支持文字消息。
3. 确认发送者 open_id 在白名单里。
4. 确认订阅的是 `im.message.receive_v1`。

### 进度消息不继续刷新

这是正常降级路径。Telegram 和飞书都会限制消息编辑频率或次数；进度面板刷不动时，最终答复仍会另发。

## 八、参考资料

- Telegram Bot API：`https://core.telegram.org/bots/api`
- 飞书开放平台：`https://open.feishu.cn`
- 项目实现：`Sources/RemoteControl.swift`、`Sources/FeishuRemote.swift`
