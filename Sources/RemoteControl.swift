// MARK: - 远程遥控:Telegram 接 cc/cx
// 主公在 Telegram 上发话,桌宠把消息当 prompt 喂给 cc/cx 的非交互模式,干完把回复回传聊天。
// cc(Claude)、cx(Codex)各占一个独立 bot;每个 Telegram 用户(chat id)在每个 bot 内各自独立:
// 独立工作目录、独立可续接会话、独立"忙"状态,互不串话。不同用户的请求并行各跑各的、谁也卡不住谁,同一用户内串行。
// 工作目录靠聊天里 /cd 切换;放手干活(跳过权限确认),与主公的 cc/cx 包装一致。
//
// 本模块刻意独立成文件(不并进 main.swift):远程链路自洽,且便于单测与维护。
// 仍由 build.sh 与 main.swift 一起 `swiftc -swift-version 5` 编译进同一二进制,共享 FeedTool / PetView / Settings。

import AppKit

/// 一次非交互调用的产物:回给用户的正文 + 新会话 id(供下一轮续接;拿不到则为 nil)+ 计量与状态(供任务监控落盘)。
struct AgentReply {
    let text: String
    let sessionID: String?
    var metrics: AgentMetrics? = nil
    var status: String = "ok"   // ok | timeout | error
}

/// 每个 Telegram 用户(chat id)在某个 bot 内的会话态:工作目录、上次会话 id、是否正忙,外加一条专属串行队列。
/// 同一用户的消息串到自己的队列里一条接一条处理(忙时拒收新消息,避免自我串话);不同用户各占一份、并行互不阻塞。
/// 字段被轮询线程(指令)与队列线程(跑 agent)共同读写,统一用 lock 保护;读写都极短,绝不在持锁期间跑 agent。
final class ChatContext {
    let tool: FeedTool
    let queue: DispatchQueue
    private let lock = NSLock()
    private var _cwd: String
    private var _sessionID: String?
    private var _busy = false

    init(tool: FeedTool, cwd: String, label: String) {
        self.tool = tool
        self._cwd = cwd
        self.queue = DispatchQueue(label: label)
    }

    var cwd: String { lock.lock(); defer { lock.unlock() }; return _cwd }
    func setCwd(_ value: String) { lock.lock(); _cwd = value; lock.unlock() }
    func setSessionID(_ value: String?) { lock.lock(); _sessionID = value; lock.unlock() }

    /// 取一份 cwd + sessionID 快照供跑 agent 用,避免持锁跨越整轮调用。
    func snapshot() -> (cwd: String, sessionID: String?) {
        lock.lock(); defer { lock.unlock() }
        return (_cwd, _sessionID)
    }

    /// 空闲则占用并返回 true;已忙返回 false(轮询线程据此立即回提示,不排队)。
    func tryBegin() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if _busy { return false }
        _busy = true
        return true
    }
    func end() { lock.lock(); _busy = false; lock.unlock() }
}

/// 非交互跑 cc/cx:拼命令、起 Process、解析输出。纯同步阻塞,调用方务必放后台线程。
enum AgentRunner {
    /// 单轮超时(秒):超时即杀进程,回报超时,避免一条卡死的会话把 bot 轮询线程拖住。
    static let timeout: TimeInterval = 600

    /// 定位官方 claude / codex 可执行路径(绕过 cc/cx 包装,自己显式加跳过权限参数,参数全可控)。找不到返回 nil。
    static func resolveExecutable(for tool: FeedTool) -> String? {
        let absolute: [String]
        let names: [String]
        switch tool {
        case .claude:
            absolute = ["/opt/homebrew/bin/claude", "/usr/local/bin/claude"]
            names = ["claude"]
        case .codex:
            absolute = ["/opt/homebrew/bin/codex", "/usr/local/bin/codex"]
            names = ["codex"]
        }
        for path in absolute where FileManager.default.isExecutableFile(atPath: path) {
            return path
        }
        for name in names { if let path = which(name) { return path } }
        return nil
    }

    /// 在登录 shell 里 `command -v` 查命令绝对路径(交互 shell 才有 Homebrew 等 PATH);查不到返回 nil。
    private static func which(_ name: String) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-lc", "command -v \(name)"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        do { try process.run(); process.waitUntilExit() } catch { return nil }
        let raw = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let path = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return (path.hasPrefix("/") && FileManager.default.isExecutableFile(atPath: path)) ? path : nil
    }

    /// 拼非交互命令(纯函数,便于 --telegram-dryrun 离线核对):
    /// claude → `-p <prompt> --output-format stream-json --verbose --dangerously-skip-permissions [--resume <sid>]`
    /// codex  → `exec [resume <sid>] --json --dangerously-bypass-approvals-and-sandbox --skip-git-repo-check [-C <cwd>] -o <lastFile> <prompt>`
    /// 两端都按行吐 JSONL(逐行事件),供流式进度解析;claude 的 stream-json 必须配 --verbose 才出中间事件。
    /// claude 没有 --cwd,靠调用方设 Process 工作目录;codex 首轮走 -C,续接靠 Process 工作目录(resume 子命令不认 -C)。lastFile 仅 codex 用来回收末条消息。
    static func command(for tool: FeedTool, prompt: String, sessionID: String?, cwd: String, lastFile: String) -> [String] {
        switch tool {
        case .claude:
            var args = ["-p", prompt, "--output-format", "stream-json", "--verbose", "--dangerously-skip-permissions"]
            if let sid = sessionID, !sid.isEmpty { args += ["--resume", sid] }
            return args
        case .codex:
            // codex exec 认 -C/--cd,但其 resume 子命令不认(0.140.0 实测报 "unexpected argument '-C'",
            // 续接轮必挂);故续接省略 -C,工作目录由调用方设的 Process.currentDirectoryURL 兜底。
            var args = ["exec"]
            let resuming = (sessionID?.isEmpty == false)
            if let sid = sessionID, resuming { args += ["resume", sid] }
            args += ["--json", "--dangerously-bypass-approvals-and-sandbox", "--skip-git-repo-check"]
            if !resuming { args += ["-C", cwd] }
            args += ["-o", lastFile, prompt]
            return args
        }
    }

    /// 流式事件:把一行 JSONL 归一成"该怎么用"。一行可能产出多条(claude 的 assistant 含多个 tool_use)。
    enum StreamEvent {
        case progress(String)   // 一行人话进度(发起的工具调用 / 中间话)
        case finalText(String)  // 最终正文候选(claude result / codex agent_message)
        case session(String)    // 会话 id(下轮续接)
        case metrics(AgentMetrics) // 计量(claude result 自报的时长 / 花费 / token)
    }

    /// 真跑一轮(流式):定位命令 → 起进程 → 边读 stdout 行边解析 → onProgress 实时抛进度 → 进程结束汇总最终回复。
    /// claude 走 --output-format stream-json、codex 走 --json,两端都按行吐 JSONL;逐行既喂进度也攒最终正文与会话 id。
    /// 失败统一回成 AgentReply 文本(让用户在 Telegram 看到原因),不抛异常。
    /// onProgress 在读取线程里同步回调(发送频率由调用方节流);ioTag 隔离 codex 的 -o 落地文件,多用户并发各写各的。
    static func run(tool: FeedTool, prompt: String, sessionID: String?, cwd: String, ioTag: String,
                    onProgress: ((String) -> Void)? = nil) -> AgentReply {
        guard let exe = resolveExecutable(for: tool) else {
            return AgentReply(text: "找不到 \(tool.label) CLI,请先安装或加入 PATH。", sessionID: sessionID, status: "error")
        }
        let lastFile = NSTemporaryDirectory() + "claudepet-remote-\(tool == .codex ? "cx" : "cc")-\(ioTag)-last.txt"
        try? FileManager.default.removeItem(atPath: lastFile)
        let args = command(for: tool, prompt: prompt, sessionID: sessionID, cwd: cwd, lastFile: lastFile)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: exe)
        process.arguments = args
        process.currentDirectoryURL = URL(fileURLWithPath: cwd)
        process.standardInput = FileHandle.nullDevice   // 无人值守:断开 stdin,免得 codex 卡在"读 stdin"
        let outPipe = Pipe(); let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe

        do { try process.run() } catch {
            return AgentReply(text: "启动 \(tool.label) 失败:\(error.localizedDescription)", sessionID: sessionID, status: "error")
        }

        // stdout 流式逐行解析:进度即时回调,最终正文与会话 id 攒进下面两个变量。
        // 二者只被读取线程写;主线程一律在 readDone 之后才读,信号量建立 happens-before,无数据竞争。
        var finalText = ""
        var resolvedSID = sessionID
        var metrics: AgentMetrics? = nil
        let readDone = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            streamLines(from: outPipe.fileHandleForReading) { line in
                for event in parseStreamLine(line, tool: tool) {
                    switch event {
                    case .progress(let p): onProgress?(p)
                    case .finalText(let t): if !t.isEmpty { finalText = t }
                    case .session(let s): if !s.isEmpty { resolvedSID = s }
                    case .metrics(let m): metrics = m
                    }
                }
            }
            readDone.signal()
        }

        // 超时守护:到点 terminate;terminate 令 stdout EOF,读取线程随之收尾。
        let exited = DispatchSemaphore(value: 0)
        DispatchQueue.global().async { process.waitUntilExit(); exited.signal() }
        if exited.wait(timeout: .now() + timeout) == .timedOut {
            process.terminate()
            readDone.wait()
            let body = finalText.isEmpty ? "\(tool.label) 超时(>\(Int(timeout))s),已中断这一轮。" : finalText
            return AgentReply(text: body, sessionID: resolvedSID, metrics: metrics, status: "timeout")
        }
        readDone.wait()   // 进程已退,等 stdout 读尽

        // codex 最终正文优先取 -o 落地文件(完整、不丢格式);claude 以 result 事件正文为准。
        if tool == .codex,
           let f = (try? String(contentsOfFile: lastFile, encoding: .utf8))?
               .trimmingCharacters(in: .whitespacesAndNewlines), !f.isEmpty {
            finalText = f
        }
        var status = "ok"
        if finalText.isEmpty {
            let stderr = String(data: errPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            finalText = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            if !finalText.isEmpty { status = "error" }   // 正文空、靠 stderr 兜底:视为出错
        }
        return AgentReply(text: finalText.isEmpty ? "(无输出)" : finalText, sessionID: resolvedSID,
                          metrics: metrics, status: finalText.isEmpty ? "error" : status)
    }

    /// 阻塞逐行读 FileHandle 到 EOF,每整行(剥掉换行)回调一次;EOF 时补回残行。
    private static func streamLines(from handle: FileHandle, _ onLine: (String) -> Void) {
        var buffer = Data()
        while true {
            let chunk = handle.availableData
            if chunk.isEmpty { break }   // EOF
            buffer.append(chunk)
            while let nl = buffer.firstIndex(of: 0x0A) {
                let lineData = buffer.subdata(in: buffer.startIndex..<nl)
                buffer.removeSubrange(buffer.startIndex...nl)
                if let line = String(data: lineData, encoding: .utf8) { onLine(line) }
            }
        }
        if !buffer.isEmpty, let line = String(data: buffer, encoding: .utf8) { onLine(line) }
    }

    /// 把一行 JSONL 解析成流式事件;空行/非 JSON 返回空,不影响主流程。是离线自测(--telegram-stream-dryrun)的核对点。
    static func parseStreamLine(_ line: String, tool: FeedTool) -> [StreamEvent] {
        guard let data = line.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [] }
        switch tool {
        case .claude: return parseClaudeEvent(obj)
        case .codex:  return parseCodexEvent(obj)
        }
    }

    /// claude stream-json:system/init 报就绪并带会话 id;assistant 的 text/tool_use 转进度;result 给最终正文。
    private static func parseClaudeEvent(_ obj: [String: Any]) -> [StreamEvent] {
        var events: [StreamEvent] = []
        if let sid = obj["session_id"] as? String, !sid.isEmpty { events.append(.session(sid)) }
        switch obj["type"] as? String {
        case "system":
            if (obj["subtype"] as? String) == "init" { events.append(.progress("🟢 已就绪,开跑")) }
        case "assistant":
            if let msg = obj["message"] as? [String: Any], let content = msg["content"] as? [[String: Any]] {
                for item in content {
                    switch item["type"] as? String {
                    case "text":
                        let t = (item["text"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                        if !t.isEmpty { events.append(.progress("💬 " + brief(t))) }
                    case "tool_use":
                        let name = item["name"] as? String ?? "工具"
                        events.append(.progress("🔧 " + claudeToolBrief(name: name, input: item["input"] as? [String: Any])))
                    default: break
                    }
                }
            }
        case "result":
            let r = (obj["result"] as? String) ?? (obj["error"] as? String) ?? ""
            if !r.isEmpty { events.append(.finalText(r)) }
            // result 事件自带本轮计量:CLI 时长 / 花费 / token,捞给任务监控落盘。
            var m = AgentMetrics()
            m.cliDurationMs = obj["duration_ms"] as? Int
            m.costUSD = obj["total_cost_usd"] as? Double
            m.numTurns = obj["num_turns"] as? Int
            if let usage = obj["usage"] as? [String: Any] {
                let cacheRead = usage["cache_read_input_tokens"] as? Int ?? 0
                let cacheCreate = usage["cache_creation_input_tokens"] as? Int ?? 0
                let input = usage["input_tokens"] as? Int ?? 0
                m.inputTokens = input + cacheRead + cacheCreate
                m.outputTokens = usage["output_tokens"] as? Int
            }
            events.append(.metrics(m))
        default: break
        }
        return events
    }

    /// codex --json:thread.started 带会话 id(字段是 thread_id,旧版本写 thread.id,这里只认实测的 thread_id);
    /// item.started 报发起的命令,item.completed 收回话(兼最终正文)。
    private static func parseCodexEvent(_ obj: [String: Any]) -> [StreamEvent] {
        switch obj["type"] as? String {
        case "thread.started":
            var events: [StreamEvent] = []
            if let tid = obj["thread_id"] as? String, !tid.isEmpty { events.append(.session(tid)) }
            events.append(.progress("🟢 开跑"))
            return events
        case "item.started":
            return (obj["item"] as? [String: Any]).map { codexItemProgress($0, started: true) } ?? []
        case "item.completed":
            return (obj["item"] as? [String: Any]).map { codexItemProgress($0, started: false) } ?? []
        default:
            return []
        }
    }

    /// codex item 转进度/最终正文:命令在发起时报一行(免完成时翻倍),回话在完成时收(兼最终正文兜底)。
    private static func codexItemProgress(_ item: [String: Any], started: Bool) -> [StreamEvent] {
        switch item["type"] as? String {
        case "command_execution":
            guard started else { return [] }
            return [.progress("🔧 $ " + brief((item["command"] as? String) ?? "", limit: 80))]
        case "agent_message":
            guard !started else { return [] }
            let text = (item["text"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return text.isEmpty ? [] : [.progress("💬 " + brief(text)), .finalText(text)]
        case "file_change", "patch":
            guard started else { return [] }
            return [.progress("📝 改动文件")]
        case "reasoning":
            return []   // 思考过程不外显
        case let other?:
            guard started else { return [] }
            return [.progress("▸ " + other)]
        default:
            return []
        }
    }

    /// claude 工具调用浓缩成一行:Bash 显命令、读写显文件名、检索显模式,其余显工具名。
    private static func claudeToolBrief(name: String, input: [String: Any]?) -> String {
        guard let input = input else { return name }
        func s(_ k: String) -> String? { (input[k] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) }
        switch name {
        case "Bash":
            return "$ " + brief(s("command") ?? "", limit: 80)
        case "Read", "Edit", "Write", "MultiEdit", "NotebookEdit":
            return name + " " + ((s("file_path").map { ($0 as NSString).lastPathComponent }) ?? "")
        case "Grep", "Glob":
            return name + " " + (s("pattern") ?? s("query") ?? "")
        case "WebFetch", "WebSearch":
            return name + " " + (s("url") ?? s("query") ?? "")
        case "Task":
            return "Task " + brief(s("description") ?? "", limit: 40)
        default:
            return name
        }
    }

    /// 取首行并截断,把多行/长文压成进度面板用的一行短摘要。
    private static func brief(_ text: String, limit: Int = 60) -> String {
        let oneLine = text.split(whereSeparator: \.isNewline).first.map(String.init) ?? text
        return oneLine.count > limit ? String(oneLine.prefix(limit)) + "…" : oneLine
    }
}

/// 进度面板:累积 cc/cx 的步骤行,只保留尾部若干行,原地刷新同一条 Telegram 消息;自带时间节流,避免触发编辑限流。
/// 仅由 AgentRunner 的读取线程(onProgress)串行访问 append/shouldFlush/render;收尾的 renderDone 在读取线程结束后才被主流程调用,无并发。
final class ProgressPanel {
    private let title: String
    private let maxLines: Int
    private let minInterval: TimeInterval
    private var lines: [String] = []
    private var omitted = 0
    private var lastFlush = Date.distantPast
    private var lastRendered = ""

    init(title: String, maxLines: Int = 12, minInterval: TimeInterval = 1.8) {
        self.title = title
        self.maxLines = maxLines
        self.minInterval = minInterval
    }

    /// 追加一行进度;超过窗口上限就丢最旧的,只留尾部。
    func append(_ line: String) {
        lines.append(line)
        if lines.count > maxLines { lines.removeFirst(); omitted += 1 }
    }

    /// 距上次刷新够久且内容确有变化才放行(true 时调用方真正发编辑请求),省掉无谓的限流消耗。
    func shouldFlush() -> Bool {
        let now = Date()
        guard now.timeIntervalSince(lastFlush) >= minInterval else { return false }
        let body = render()
        guard body != lastRendered else { return false }
        lastFlush = now
        lastRendered = body
        return true
    }

    /// 当前面板文本:标题(含省略提示)+ 尾部若干步。
    func render() -> String {
        var head = title
        if omitted > 0 { head += "(略过前 \(omitted) 步)" }
        return ([head] + lines).joined(separator: "\n")
    }

    /// 收尾文本:面板末尾标注已答完,最终正文在下一条消息。
    func renderDone() -> String {
        return render() + "\n— — —\n✅ 已答完,见下条。"
    }
}

/// 一个 Telegram bot 的轮询器:long polling 收消息 → 解析指令/喂 agent → 回话。
/// 每个实例绑定一个 token + 一个 tool(cc 或 cx);按 chat id 各建一份 ChatContext,
/// 不同用户并行、各记各的目录与上下文,同一用户串行,所以谁也不串话、谁也卡不住谁。
final class TelegramBot {
    private let token: String
    private let tool: FeedTool
    private let home: String                  // 新用户的默认工作目录
    private let allowedChatIDs: Set<String>
    /// 桌宠联动回调:phase ∈ "start"(收到消息开干) / "done"(干完);summary 给横幅。主线程里调。
    private let onActivity: (FeedTool, String, String?) -> Void

    /// 按 chat id 索引的会话态。只在轮询线程(loop→handle)里查/建,故无需为字典本身加锁。
    private var contexts: [String: ChatContext] = [:]
    private var offset = 0
    private var running = false
    private let urlSession: URLSession

    init(token: String, tool: FeedTool, home: String, allowedChatIDs: Set<String>,
         onActivity: @escaping (FeedTool, String, String?) -> Void) {
        self.token = token
        self.tool = tool
        self.home = home
        self.allowedChatIDs = allowedChatIDs
        self.onActivity = onActivity
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 70   // long polling timeout=50,留余量
        cfg.timeoutIntervalForResource = 120
        self.urlSession = URLSession(configuration: cfg)
    }

    /// 取该 chat 的会话态,没有就按默认目录新建。仅轮询线程调用,无需加锁。
    private func context(for chatID: String) -> ChatContext {
        if let ctx = contexts[chatID] { return ctx }
        let tag = tool == .codex ? "cx" : "cc"
        let ctx = ChatContext(tool: tool, cwd: home, label: "claudepet.remote.\(tag).\(chatID)")
        contexts[chatID] = ctx
        PetView.log("Telegram[\(tool.label)] 新建会话 chat \(chatID),默认目录 \(home)")
        return ctx
    }

    func start() {
        guard !running else { return }
        running = true
        Thread.detachNewThread { [weak self] in self?.loop() }
        PetView.log("Telegram[\(tool.label)] 轮询启动,默认目录 \(home)")
    }

    func stop() { running = false }

    // MARK: 轮询主循环
    private func loop() {
        while running {
            guard let updates = getUpdates() else {
                Thread.sleep(forTimeInterval: 5)   // 网络抖动:歇 5 秒再试,不刷屏
                continue
            }
            for update in updates {
                if let updateID = update["update_id"] as? Int { offset = max(offset, updateID + 1) }
                handle(update)
            }
        }
    }

    /// GET getUpdates(long polling)。返回 result 数组;失败返回 nil。
    private func getUpdates() -> [[String: Any]]? {
        var comps = URLComponents(string: "https://api.telegram.org/bot\(token)/getUpdates")!
        comps.queryItems = [
            URLQueryItem(name: "timeout", value: "50"),
            URLQueryItem(name: "offset", value: String(offset)),
        ]
        guard let obj = syncGET(comps.url) else { return nil }
        guard (obj["ok"] as? Bool) == true else {
            PetView.log("Telegram[\(tool.label)] getUpdates 非 ok: \(obj["description"] as? String ?? "?")")
            return nil
        }
        return obj["result"] as? [[String: Any]] ?? []
    }

    /// 处理一条 update:白名单校验 → 取该 chat 的会话态 → 指令(/cd /pwd /new /help)或普通消息(喂 agent)。
    private func handle(_ update: [String: Any]) {
        guard let message = update["message"] as? [String: Any],
              let text = (message["text"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !text.isEmpty,
              let chat = message["chat"] as? [String: Any] else { return }
        let chatID = String(describing: chat["id"] ?? "")
        // 发起人可读名:优先 @username,退而 first_name + last_name,再退 chat id。供任务监控展示"具体谁发起的"。
        let senderName = TelegramBot.senderDisplayName(from: message["from"] as? [String: Any], chatID: chatID)

        // 白名单:非空时只认名单内 chat;空名单放行但记日志提醒主公尽快设白名单。
        if !allowedChatIDs.isEmpty, !allowedChatIDs.contains(chatID) {
            PetView.log("Telegram[\(tool.label)] 拒收 chat \(chatID)(不在白名单)")
            sendMessage(chatID: chatID, text: "你不在白名单里,无法下发指令。")
            return
        }
        if allowedChatIDs.isEmpty {
            PetView.log("Telegram[\(tool.label)] 警告:未设白名单,chat \(chatID) 已放行")
        }

        let ctx = context(for: chatID)
        if text.hasPrefix("/") { handleCommand(text, ctx: ctx, chatID: chatID); return }
        // 占用失败=该用户上一条还在跑:立即回提示,绝不排队(否则轮询线程也会被拖住)。
        guard ctx.tryBegin() else {
            sendMessage(chatID: chatID, text: "上一条还在跑,等它答完再发哈。")
            return
        }
        runAgent(prompt: text, ctx: ctx, chatID: chatID, senderName: senderName)
    }

    /// 从 Telegram message.from 拼一个可读发起人名:@username 优先,再 first_name [last_name],兜底 chat id。
    static func senderDisplayName(from raw: [String: Any]?, chatID: String) -> String {
        guard let from = raw else { return chatID }
        if let username = from["username"] as? String, !username.isEmpty { return "@" + username }
        let first = (from["first_name"] as? String) ?? ""
        let last = (from["last_name"] as? String) ?? ""
        let full = (first + " " + last).trimmingCharacters(in: .whitespaces)
        return full.isEmpty ? chatID : full
    }

    /// 斜杠指令:/cd 切目录、/pwd 看目录、/new 开新会话、/help 用法。只动该 chat 自己的会话态。
    private func handleCommand(_ text: String, ctx: ChatContext, chatID: String) {
        let parts = text.split(separator: " ", maxSplits: 1).map(String.init)
        let cmd = parts[0].lowercased()
        let arg = parts.count > 1 ? parts[1].trimmingCharacters(in: .whitespaces) : ""
        switch cmd {
        case "/cd":
            let expanded = (arg as NSString).expandingTildeInPath
            var isDir: ObjCBool = false
            guard !arg.isEmpty, FileManager.default.fileExists(atPath: expanded, isDirectory: &isDir), isDir.boolValue else {
                sendMessage(chatID: chatID, text: "目录不存在:\(arg.isEmpty ? "(空)" : arg)")
                return
            }
            ctx.setCwd(expanded)
            ctx.setSessionID(nil)   // 换目录即开新会话,免得上下文跨项目串味
            sendMessage(chatID: chatID, text: "已切到 \(expanded),并开了新会话。")
        case "/pwd":
            sendMessage(chatID: chatID, text: "当前目录:\(ctx.cwd)")
        case "/new":
            ctx.setSessionID(nil)
            sendMessage(chatID: chatID, text: "已开新会话,之前的上下文清空。")
        case "/help", "/start":
            sendMessage(chatID: chatID, text: """
            我是 \(tool.label) 远程遥控。直接发消息我就替你干活;支持:
            /cd <路径>  切换工作目录(并开新会话)
            /pwd        看当前目录
            /new        开新会话(清上下文)
            /help       这条帮助
            当前目录:\(ctx.cwd)
            """)
        default:
            sendMessage(chatID: chatID, text: "不认得指令 \(cmd),发 /help 看用法。")
        }
    }

    /// 把消息当 prompt 喂给 agent:派到该 chat 的串行队列后台跑,轮询线程立刻返回继续收别人的消息。
    /// 流程:桌宠开跑 → 先占一条进度消息 → 边跑边把 cc/cx 的步骤原地编辑进这条消息 → 写回会话 id、解忙 → 收尾进度 + 另发最终正文 → 桌宠收工。
    /// 调用前 handle 已 tryBegin() 占用。进度回调在 AgentRunner 的读取线程里触发,经 ProgressPanel 节流后才真正发编辑请求,避免触发 Telegram 限流。
    private func runAgent(prompt: String, ctx: ChatContext, chatID: String, senderName: String) {
        let tool = self.tool
        ctx.queue.async { [weak self] in
            guard let self = self else { return }
            DispatchQueue.main.async { self.onActivity(tool, "start", nil) }
            PetView.log("Telegram[\(tool.label)] chat \(chatID) 收到 \(prompt.count) 字,开跑")
            let startedAt = Date()   // 墙钟计时起点:供任务监控算"运行了多长时间"

            // 先占一条进度消息,随后原地编辑刷新;拿不到 message_id 则退化为只在跑完发结果。
            let panelID = self.sendMessage(chatID: chatID, text: "🤖 收到,开跑…")
            let panel = ProgressPanel(title: "\(tool.label) 远程进度")

            let snap = ctx.snapshot()
            let reply = AgentRunner.run(tool: tool, prompt: prompt, sessionID: snap.sessionID,
                                        cwd: snap.cwd, ioTag: chatID) { [weak self] line in
                guard let self = self, let panelID = panelID else { return }
                panel.append(line)
                if panel.shouldFlush() { self.editMessageText(chatID: chatID, messageID: panelID, text: panel.render()) }
            }
            ctx.setSessionID(reply.sessionID)
            ctx.end()

            // 任务监控:落盘本轮"问题→答案"连同发起人、耗时、花费(开关关闭时 record 内部直接跳过)。
            DispatchQueue.main.async {
                TaskMonitor.record(source: "telegram", tool: tool, initiatorID: chatID, initiatorName: senderName,
                                   cwd: snap.cwd, question: prompt, answer: reply.text,
                                   startedAt: startedAt, endedAt: Date(), status: reply.status,
                                   sessionID: reply.sessionID, metrics: reply.metrics)
            }

            // 进度面板收尾(强制刷最后一版),最终正文另发(可能多段、长文)。
            if let panelID = panelID {
                self.editMessageText(chatID: chatID, messageID: panelID, text: panel.renderDone())
            }
            self.sendMessage(chatID: chatID, text: reply.text)
            let summary = reply.text.split(whereSeparator: \.isNewline).first.map(String.init) ?? reply.text
            DispatchQueue.main.async { self.onActivity(tool, "done", String(summary.prefix(40))) }
        }
    }

    // MARK: 回话
    /// 发消息回 Telegram;>4000 字按段切(上限 4096),逐段发。返回最后一段的 message_id(占位进度消息靠它后续原地编辑)。
    @discardableResult
    private func sendMessage(chatID: String, text: String) -> Int? {
        var lastMessageID: Int?
        for chunk in TelegramBot.chunks(text, limit: 4000) {
            var req = URLRequest(url: URL(string: "https://api.telegram.org/bot\(token)/sendMessage")!)
            req.httpMethod = "POST"
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            let body: [String: Any] = ["chat_id": chatID, "text": chunk]
            req.httpBody = try? JSONSerialization.data(withJSONObject: body)
            if let obj = syncData(req), let result = obj["result"] as? [String: Any],
               let mid = result["message_id"] as? Int { lastMessageID = mid }
        }
        return lastMessageID
    }

    /// 原地编辑既有消息(进度面板刷新用)。Telegram 对"内容未变"会回 400,无害,忽略。
    private func editMessageText(chatID: String, messageID: Int, text: String) {
        var req = URLRequest(url: URL(string: "https://api.telegram.org/bot\(token)/editMessageText")!)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body: [String: Any] = ["chat_id": chatID, "message_id": messageID, "text": text]
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        _ = syncData(req)
    }

    /// 按字符上限切段(尽量在换行处断),保证每段不超 Telegram 限制。
    static func chunks(_ text: String, limit: Int) -> [String] {
        guard text.count > limit else { return [text.isEmpty ? "(空)" : text] }
        var result: [String] = []
        var current = ""
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            if current.count + line.count + 1 > limit {
                if !current.isEmpty { result.append(current); current = "" }
                if line.count > limit {   // 单行超长:硬切
                    var rest = Substring(line)
                    while rest.count > limit {
                        result.append(String(rest.prefix(limit)))
                        rest = rest.dropFirst(limit)
                    }
                    current = String(rest)
                    continue
                }
            }
            current += (current.isEmpty ? "" : "\n") + line
        }
        if !current.isEmpty { result.append(current) }
        return result
    }

    // MARK: HTTP 同步原语(轮询线程本就阻塞,同步最直白)
    private func syncGET(_ url: URL?) -> [String: Any]? {
        guard let url = url else { return nil }
        return syncData(URLRequest(url: url))
    }

    private func syncData(_ request: URLRequest) -> [String: Any]? {
        let sem = DispatchSemaphore(value: 0)
        var result: [String: Any]?
        let task = urlSession.dataTask(with: request) { data, _, _ in
            defer { sem.signal() }
            guard let data = data,
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
            result = obj
        }
        task.resume()
        sem.wait()
        return result
    }
}

/// 远程遥控协调器:按设置起停 cc/cx 两个 bot,把活动回调转给桌宠。单例,主线程访问。
@MainActor
final class RemoteControl {
    static let shared = RemoteControl()
    private var bots: [TelegramBot] = []
    private var feishuBots: [FeishuBot] = []
    /// 桌宠联动回调,由 main.swift 的 AppDelegate 注入(那里能访问 PetView);本模块只管在主线程回调,不碰 PetView 类型。
    var onActivity: ((FeedTool, String, String?) -> Void)?
    private init() {}

    /// 按当前设置重建 bot:先全停,再按总开关 + 凭证起。Telegram 与飞书共用 remoteEnabled 总开关。设置变更或启动时调用。
    func reload() {
        bots.forEach { $0.stop() }
        bots.removeAll()
        feishuBots.forEach { $0.stop() }
        feishuBots.removeAll()
        guard Settings.remoteEnabled else {
            PetView.log("远程遥控未启用,跳过")
            return
        }
        let home = FileManager.default.homeDirectoryForCurrentUser.path

        // Telegram:cc/cx 各自 token 非空才起。
        let allow = Settings.telegramAllowedChatIDSet
        let claudeToken = Settings.telegramClaudeToken
        let codexToken = Settings.telegramCodexToken
        if !claudeToken.isEmpty { bots.append(makeBot(token: claudeToken, tool: .claude, home: home, allow: allow)) }
        if !codexToken.isEmpty { bots.append(makeBot(token: codexToken, tool: .codex, home: home, allow: allow)) }
        bots.forEach { $0.start() }

        // 飞书:cc/cx 各自的应用凭证(app_id + app_secret)齐全才起。
        let feishuAllow = Settings.feishuAllowedOpenIDSet
        if !Settings.feishuClaudeAppID.isEmpty, !Settings.feishuClaudeAppSecret.isEmpty {
            feishuBots.append(makeFeishuBot(appID: Settings.feishuClaudeAppID, appSecret: Settings.feishuClaudeAppSecret,
                                            tool: .claude, home: home, allow: feishuAllow))
        }
        if !Settings.feishuCodexAppID.isEmpty, !Settings.feishuCodexAppSecret.isEmpty {
            feishuBots.append(makeFeishuBot(appID: Settings.feishuCodexAppID, appSecret: Settings.feishuCodexAppSecret,
                                            tool: .codex, home: home, allow: feishuAllow))
        }
        feishuBots.forEach { $0.start() }

        PetView.log("远程遥控重载:Telegram \(bots.count) 个 bot,飞书 \(feishuBots.count) 个 bot")
    }

    private func makeBot(token: String, tool: FeedTool, home: String, allow: Set<String>) -> TelegramBot {
        return TelegramBot(token: token, tool: tool, home: home, allowedChatIDs: allow) { [weak self] tool, phase, summary in
            self?.onActivity?(tool, phase, summary)
        }
    }

    private func makeFeishuBot(appID: String, appSecret: String, tool: FeedTool, home: String, allow: Set<String>) -> FeishuBot {
        return FeishuBot(appID: appID, appSecret: appSecret, tool: tool, home: home, allowedOpenIDs: allow) { [weak self] tool, phase, summary in
            self?.onActivity?(tool, phase, summary)
        }
    }
}

/// 远程遥控配置窗:独立小窗,不挤进已爆满的主设置窗。手写 AppKit 绝对布局。
/// 收总开关 + cc/cx 两个 bot token + chat id 白名单;保存即写 UserDefaults 并 RemoteControl.reload。
@MainActor
final class RemoteControlWindowController: NSWindowController {
    private let enabledButton = NSButton(checkboxWithTitle: "启用远程遥控(Telegram / 飞书 共用总开关)", target: nil, action: nil)
    private let claudeTokenField = NSTextField(string: "")
    private let codexTokenField = NSTextField(string: "")
    private let allowedField = NSTextField(string: "")
    private let feishuClaudeAppIDField = NSTextField(string: "")
    private let feishuClaudeAppSecretField = NSTextField(string: "")
    private let feishuCodexAppIDField = NSTextField(string: "")
    private let feishuCodexAppSecretField = NSTextField(string: "")
    private let feishuAllowedField = NSTextField(string: "")

    init() {
        let content = NSView(frame: NSRect(x: 0, y: 0, width: 460, height: 720))
        let window = NSWindow(contentRect: content.frame, styleMask: [.titled, .closable],
                              backing: .buffered, defer: false)
        window.title = "远程遥控(Telegram / 飞书)"
        window.isReleasedWhenClosed = false
        window.contentView = content
        super.init(window: window)
        buildContent(in: content)
        reflect()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("不支持 Interface Builder 加载") }

    private func buildContent(in content: NSView) {
        func label(_ text: String, y: CGFloat, secondary: Bool = false) {
            let l = NSTextField(labelWithString: text)
            if secondary { l.textColor = .secondaryLabelColor; l.font = .systemFont(ofSize: 11) }
            l.frame = NSRect(x: 24, y: y, width: 412, height: secondary ? 16 : 20)
            content.addSubview(l)
        }
        func section(_ text: String, y: CGFloat) {
            let l = NSTextField(labelWithString: text)
            l.font = .boldSystemFont(ofSize: 12)
            l.frame = NSRect(x: 24, y: y, width: 412, height: 20)
            content.addSubview(l)
        }
        func note(_ text: String, y: CGFloat) {
            let l = NSTextField(labelWithString: text)
            l.textColor = .secondaryLabelColor; l.font = .systemFont(ofSize: 11)
            l.frame = NSRect(x: 24, y: y, width: 412, height: 16)
            content.addSubview(l)
        }
        func field(_ tf: NSTextField, y: CGFloat) {
            tf.frame = NSRect(x: 24, y: y, width: 412, height: 24)
            tf.lineBreakMode = .byTruncatingTail
            content.addSubview(tf)
        }

        // 顶部:Telegram 与飞书共用的总开关
        enabledButton.target = self
        enabledButton.action = #selector(enabledChanged(_:))
        enabledButton.frame = NSRect(x: 24, y: 684, width: 412, height: 24)
        content.addSubview(enabledButton)

        // ── Telegram ──
        section("Telegram", y: 652)
        note("找 @BotFather 各建一个 bot 拿 token;给 bot 发条消息后用 getUpdates 看 chat id。", y: 634)
        label("Claude(cc)bot token", y: 608); field(claudeTokenField, y: 584)
        label("Codex(cx)bot token", y: 556); field(codexTokenField, y: 532)
        label("允许的 chat id(逗号/空格分隔,留空=不限,但不安全)", y: 504); field(allowedField, y: 480)

        // ── 飞书 ──
        section("飞书(Feishu,仅国内版 open.feishu.cn)", y: 444)
        note("各建企业自建应用:开机器人 + im:message 权限,事件订阅选「长连接」订 im.message.receive_v1。", y: 422)
        label("Claude(cc)App ID", y: 398); field(feishuClaudeAppIDField, y: 374)
        label("Claude(cc)App Secret", y: 346); field(feishuClaudeAppSecretField, y: 322)
        label("Codex(cx)App ID", y: 294); field(feishuCodexAppIDField, y: 270)
        label("Codex(cx)App Secret", y: 242); field(feishuCodexAppSecretField, y: 218)
        label("允许的 open_id(逗号/空格分隔,留空=不限,但不安全)", y: 190); field(feishuAllowedField, y: 166)

        // 底部提示 + 按钮
        let tip = NSTextField(labelWithString: "改完点「保存并应用」立即生效;凭证留空则对应 bot 不启动。\ntoken / app secret 只存本机,不入仓库。")
        tip.textColor = .secondaryLabelColor; tip.font = .systemFont(ofSize: 11)
        tip.maximumNumberOfLines = 2
        tip.frame = NSRect(x: 24, y: 106, width: 412, height: 34)
        content.addSubview(tip)

        let save = NSButton(title: "保存并应用", target: self, action: #selector(saveAndApply(_:)))
        save.bezelStyle = .rounded
        save.keyEquivalent = "\r"
        save.frame = NSRect(x: 250, y: 24, width: 110, height: 30)
        content.addSubview(save)
        let close = NSButton(title: "关闭", target: self, action: #selector(closeRemote(_:)))
        close.bezelStyle = .rounded
        close.frame = NSRect(x: 366, y: 24, width: 70, height: 30)
        content.addSubview(close)
    }

    /// 回填:把当前设置映射到控件。
    private func reflect() {
        enabledButton.state = Settings.remoteEnabled ? .on : .off
        claudeTokenField.stringValue = Settings.telegramClaudeToken
        codexTokenField.stringValue = Settings.telegramCodexToken
        allowedField.stringValue = Settings.telegramAllowedChatIDs
        feishuClaudeAppIDField.stringValue = Settings.feishuClaudeAppID
        feishuClaudeAppSecretField.stringValue = Settings.feishuClaudeAppSecret
        feishuCodexAppIDField.stringValue = Settings.feishuCodexAppID
        feishuCodexAppSecretField.stringValue = Settings.feishuCodexAppSecret
        feishuAllowedField.stringValue = Settings.feishuAllowedOpenIDs
    }

    @objc private func enabledChanged(_ sender: NSButton) {
        Settings.remoteEnabled = sender.state == .on
    }

    @objc private func saveAndApply(_ sender: Any?) {
        Settings.remoteEnabled = enabledButton.state == .on
        Settings.telegramClaudeToken = claudeTokenField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        Settings.telegramCodexToken = codexTokenField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        Settings.telegramAllowedChatIDs = allowedField.stringValue
        Settings.feishuClaudeAppID = feishuClaudeAppIDField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        Settings.feishuClaudeAppSecret = feishuClaudeAppSecretField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        Settings.feishuCodexAppID = feishuCodexAppIDField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        Settings.feishuCodexAppSecret = feishuCodexAppSecretField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        Settings.feishuAllowedOpenIDs = feishuAllowedField.stringValue
        RemoteControl.shared.reload()
        let alert = NSAlert()
        alert.messageText = "已保存并应用"
        alert.informativeText = Settings.remoteEnabled ? "远程遥控已按新配置重启。" : "远程遥控已停用。"
        alert.runModal()
    }

    @objc private func closeRemote(_ sender: Any?) { window?.close() }
}
