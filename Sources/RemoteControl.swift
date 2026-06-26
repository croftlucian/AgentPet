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
        let lastFile = NSTemporaryDirectory() + "agentpet-remote-\(tool == .codex ? "cx" : "cc")-\(ioTag)-last.txt"
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
    /// item.started 报发起的命令,item.completed 收回话(兼最终正文),turn.completed 带本轮 token 计量。
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
        case "turn.completed":
            guard let usage = obj["usage"] as? [String: Any] else { return [] }
            var m = AgentMetrics()
            let input = usage["input_tokens"] as? Int ?? 0
            let output = usage["output_tokens"] as? Int ?? 0
            let reasoningOutput = usage["reasoning_output_tokens"] as? Int ?? 0
            m.inputTokens = input
            m.outputTokens = output + reasoningOutput
            return [.metrics(m)]
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
        guard lines.last != line else { return }
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

// MARK: - 远程 Bot 个性化初始化

/// 远程 Bot 的个性化记录。隔离维度固定为 platform + remoteUserID + botID:
/// 同一个人在 cc/cx、Telegram/飞书之间互不串设置,同一群里的不同发送者也互不影响。
struct RemoteBotProfileRecord: Codable {
    var platform: String
    var remoteUserID: String
    var botID: String
    var botName: String
    var userTitle: String
    var responseStyle: String
    var setupStatus: String
    var currentStep: String
    var setupMode: String
    var createdAt: Double
    var updatedAt: Double

    var isCompleted: Bool { setupStatus == "completed" }
}

/// 个性化配置持久化。配置很小,整文件读写比增量补丁更直白;所有读写串到一条队列避免并发覆盖。
enum RemoteBotProfileStore {
    private struct Database: Codable { var records: [String: RemoteBotProfileRecord] = [:] }

    private static let queue = DispatchQueue(label: "agentpet.remote.profile.store")
    static var overridePathForTesting: String?

    static var dataDirectory: String {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?.path
            ?? (NSHomeDirectory() + "/Library/Application Support")
        return base + "/com.agent.pet"
    }

    static var filePath: String { overridePathForTesting ?? (dataDirectory + "/remote-profiles.json") }

    static func key(platform: String, remoteUserID: String, botID: String) -> String {
        [platform, remoteUserID, botID].joined(separator: "|")
    }

    static func record(platform: String, remoteUserID: String, botID: String) -> RemoteBotProfileRecord? {
        queue.sync { load().records[key(platform: platform, remoteUserID: remoteUserID, botID: botID)] }
    }

    @discardableResult
    static func update(platform: String, remoteUserID: String, botID: String,
                       _ mutate: (inout RemoteBotProfileRecord) -> Void) -> RemoteBotProfileRecord {
        queue.sync {
            var db = load()
            let k = key(platform: platform, remoteUserID: remoteUserID, botID: botID)
            var rec = db.records[k] ?? RemoteBotProfileRecord(platform: platform, remoteUserID: remoteUserID, botID: botID,
                                                              botName: "", userTitle: "", responseStyle: "",
                                                              setupStatus: "choosing_mode", currentStep: "mode",
                                                              setupMode: "", createdAt: Date().timeIntervalSince1970,
                                                              updatedAt: Date().timeIntervalSince1970)
            mutate(&rec)
            rec.updatedAt = Date().timeIntervalSince1970
            db.records[k] = rec
            save(db)
            return rec
        }
    }

    static func remove(platform: String, remoteUserID: String, botID: String) {
        queue.sync {
            var db = load()
            db.records.removeValue(forKey: key(platform: platform, remoteUserID: remoteUserID, botID: botID))
            save(db)
        }
    }

    private static func load() -> Database {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: filePath)),
              let db = try? JSONDecoder().decode(Database.self, from: data) else { return Database() }
        return db
    }

    private static func save(_ db: Database) {
        do {
            try FileManager.default.createDirectory(atPath: (filePath as NSString).deletingLastPathComponent,
                                                    withIntermediateDirectories: true)
            let enc = JSONEncoder()
            enc.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try enc.encode(db)
            try data.write(to: URL(fileURLWithPath: filePath), options: .atomic)
        } catch {
            PetView.log("远程个性化配置写入失败:\(error.localizedDescription)")
        }
    }
}

enum RemoteBotSetupResult {
    case reply(String, resetSession: Bool)
    case proceed(String)
}

/// 远程 Bot 初始化状态机。只返回“该回什么”或“可进入 Agent 的增强 prompt”,不碰 Telegram/飞书收发细节。
enum RemoteBotSetup {
    static let defaultStyle = "正常"

    static func botID(for tool: FeedTool) -> String {
        switch tool {
        case .claude: return "claude"
        case .codex: return "codex"
        }
    }

    static func handle(platform: String, remoteUserID: String, botID: String, toolLabel: String,
                       incoming rawText: String) -> RemoteBotSetupResult {
        let text = normalized(rawText)
        let lower = text.lowercased()

        if lower == "/setup" {
            let rec = start(platform: platform, remoteUserID: remoteUserID, botID: botID)
            return .reply(intro(toolLabel: toolLabel, record: rec), resetSession: true)
        }
        if lower == "/reset" {
            RemoteBotProfileStore.remove(platform: platform, remoteUserID: remoteUserID, botID: botID)
            let rec = start(platform: platform, remoteUserID: remoteUserID, botID: botID)
            return .reply("🧹 已清空当前 Bot 设置。\n\n" + intro(toolLabel: toolLabel, record: rec), resetSession: true)
        }
        if lower == "/profile" {
            guard let rec = RemoteBotProfileStore.record(platform: platform, remoteUserID: remoteUserID, botID: botID),
                  rec.isCompleted else {
                let rec = start(platform: platform, remoteUserID: remoteUserID, botID: botID)
                return .reply("⚙️ 当前 Bot 尚未完成设置。\n\n" + intro(toolLabel: toolLabel, record: rec), resetSession: false)
            }
            return .reply(profileText(rec), resetSession: false)
        }

        guard let rec = RemoteBotProfileStore.record(platform: platform, remoteUserID: remoteUserID, botID: botID) else {
            let started = start(platform: platform, remoteUserID: remoteUserID, botID: botID)
            if text == "1" || text == "2" {
                return handleSetupInput(text, record: started, toolLabel: toolLabel)
            }
            return .reply(blockedIntro(toolLabel: toolLabel, record: started), resetSession: false)
        }

        if rec.isCompleted {
            return .proceed(decoratePrompt(rawText, profile: rec))
        }

        if text.hasPrefix("/") {
            return .reply("⚙️ 当前 Bot 尚未完成设置，请先完成个性化设置后再使用。\n\n" + currentPrompt(toolLabel: toolLabel, record: rec),
                          resetSession: false)
        }
        return handleSetupInput(text, record: rec, toolLabel: toolLabel)
    }

    static func runSelfTest() -> Bool {
        let oldPath = RemoteBotProfileStore.overridePathForTesting
        let tmp = NSTemporaryDirectory() + "agentpet-remote-profile-selftest-\(UUID().uuidString).json"
        RemoteBotProfileStore.overridePathForTesting = tmp
        defer {
            RemoteBotProfileStore.overridePathForTesting = oldPath
            try? FileManager.default.removeItem(atPath: tmp)
        }

        func expectReply(_ result: RemoteBotSetupResult, contains needle: String) -> Bool {
            if case .reply(let text, _) = result { return text.contains(needle) }
            return false
        }
        func expectProceed(_ result: RemoteBotSetupResult, contains needle: String) -> Bool {
            if case .proceed(let prompt) = result { return prompt.contains(needle) }
            return false
        }
        func check(_ label: String, _ condition: Bool) -> Bool {
            if !condition { print("  失败:\(label)") }
            return condition
        }

        let p = "telegram", u1 = "user-a", u2 = "user-b", b = "claude"
        var ok = true
        ok = check("首次普通消息被拦截", expectReply(handle(platform: p, remoteUserID: u1, botID: b, toolLabel: "cc/claude", incoming: "帮我查代码"), contains: "尚未完成设置")) && ok
        ok = check("错误数字提示", expectReply(handle(platform: p, remoteUserID: u1, botID: b, toolLabel: "cc/claude", incoming: "3"), contains: "请输入数字 1 或 2")) && ok
        ok = check("选择逐步设置", expectReply(handle(platform: p, remoteUserID: u1, botID: b, toolLabel: "cc/claude", incoming: "1"), contains: "请给这个 Bot 起一个名字")) && ok
        ok = check("Bot 名字不能为空", expectReply(handle(platform: p, remoteUserID: u1, botID: b, toolLabel: "cc/claude", incoming: "   "), contains: "不能为空")) && ok
        ok = check("填写 Bot 名字", expectReply(handle(platform: p, remoteUserID: u1, botID: b, toolLabel: "cc/claude", incoming: "德全"), contains: "请设置 Bot 对您的称呼")) && ok
        ok = check("填写称呼", expectReply(handle(platform: p, remoteUserID: u1, botID: b, toolLabel: "cc/claude", incoming: "主公"), contains: "请设置 Bot 的说话风格")) && ok
        ok = check("填写风格后确认", expectReply(handle(platform: p, remoteUserID: u1, botID: b, toolLabel: "cc/claude", incoming: "正常"), contains: "请确认当前设置")) && ok
        ok = check("确认保存", expectReply(handle(platform: p, remoteUserID: u1, botID: b, toolLabel: "cc/claude", incoming: "1"), contains: "设置已保存")) && ok
        ok = check("完成后放行增强 prompt", expectProceed(handle(platform: p, remoteUserID: u1, botID: b, toolLabel: "cc/claude", incoming: "现在可以用了"), contains: "对用户称呼：主公")) && ok
        ok = check("不同用户隔离", expectReply(handle(platform: p, remoteUserID: u2, botID: b, toolLabel: "cc/claude", incoming: "现在可以用了"), contains: "尚未完成设置")) && ok

        let q = "codex"
        ok = check("选择快速设置", expectReply(handle(platform: "feishu", remoteUserID: u1, botID: q, toolLabel: "cx/codex", incoming: "2"), contains: "请用一段话描述")) && ok
        ok = check("快速设置缺称呼追问", expectReply(handle(platform: "feishu", remoteUserID: u1, botID: q, toolLabel: "cx/codex", incoming: "你叫小智，说话正常一点。"), contains: "怎么称呼您")) && ok
        ok = check("补齐称呼后确认", expectReply(handle(platform: "feishu", remoteUserID: u1, botID: q, toolLabel: "cx/codex", incoming: "老板"), contains: "请确认当前设置")) && ok
        ok = check("确认页重新设置", expectReply(handle(platform: "feishu", remoteUserID: u1, botID: q, toolLabel: "cx/codex", incoming: "2"), contains: "请选择设置方式")) && ok
        ok = check("重新进入快速设置", expectReply(handle(platform: "feishu", remoteUserID: u1, botID: q, toolLabel: "cx/codex", incoming: "2"), contains: "请用一段话描述")) && ok
        ok = check("快速设置完整解析", expectReply(handle(platform: "feishu", remoteUserID: u1, botID: q, toolLabel: "cx/codex", incoming: "你叫德全，称呼我为主公，说话恭敬一点，但不要太啰嗦。"), contains: "请确认当前设置")) && ok
        ok = check("快速设置确认保存", expectReply(handle(platform: "feishu", remoteUserID: u1, botID: q, toolLabel: "cx/codex", incoming: "1"), contains: "设置已保存")) && ok
        ok = check("查看配置", expectReply(handle(platform: "feishu", remoteUserID: u1, botID: q, toolLabel: "cx/codex", incoming: "/profile"), contains: "Bot 名字：德全")) && ok
        ok = check("重置配置", expectReply(handle(platform: "feishu", remoteUserID: u1, botID: q, toolLabel: "cx/codex", incoming: "/reset"), contains: "已清空")) && ok
        return ok
    }

    private static func start(platform: String, remoteUserID: String, botID: String) -> RemoteBotProfileRecord {
        RemoteBotProfileStore.update(platform: platform, remoteUserID: remoteUserID, botID: botID) { rec in
            rec.botName = ""
            rec.userTitle = ""
            rec.responseStyle = ""
            rec.setupStatus = "choosing_mode"
            rec.currentStep = "mode"
            rec.setupMode = ""
        }
    }

    private static func handleSetupInput(_ text: String, record rec: RemoteBotProfileRecord,
                                         toolLabel: String) -> RemoteBotSetupResult {
        switch rec.currentStep {
        case "mode":
            if text == "1" {
                let next = RemoteBotProfileStore.update(platform: rec.platform, remoteUserID: rec.remoteUserID, botID: rec.botID) {
                    $0.setupStatus = "in_progress"; $0.setupMode = "step"; $0.currentStep = "bot_name"
                }
                return .reply(currentPrompt(toolLabel: toolLabel, record: next), resetSession: true)
            }
            if text == "2" {
                let next = RemoteBotProfileStore.update(platform: rec.platform, remoteUserID: rec.remoteUserID, botID: rec.botID) {
                    $0.setupStatus = "in_progress"; $0.setupMode = "quick"; $0.currentStep = "quick_description"
                }
                return .reply(currentPrompt(toolLabel: toolLabel, record: next), resetSession: true)
            }
            return .reply("""
            🔢 请输入数字 1 或 2。

            1️⃣ 一步步设置
            2️⃣ 用一段话快速设置
            """, resetSession: false)

        case "quick_description":
            guard let extracted = extractQuickConfig(from: text) else {
                return .reply("""
                🤔 暂时没有识别出有效设置，请重新描述。

                💡 例如：
                “你叫德全，称呼我为主公，说话正常一点。”
                """, resetSession: false)
            }
            let next = RemoteBotProfileStore.update(platform: rec.platform, remoteUserID: rec.remoteUserID, botID: rec.botID) {
                if let name = extracted.botName { $0.botName = name }
                if let title = extracted.userTitle { $0.userTitle = title }
                if let style = extracted.responseStyle { $0.responseStyle = style }
                $0.currentStep = nextMissingStep($0)
                if $0.currentStep == "confirm" { $0.setupStatus = "confirming" }
            }
            return .reply(currentPrompt(toolLabel: toolLabel, record: next), resetSession: false)

        case "bot_name":
            let checked = validateField(text, name: "Bot 名字", limit: 40)
            guard let value = checked.value else {
                return .reply(checked.message, resetSession: false)
            }
            let next = RemoteBotProfileStore.update(platform: rec.platform, remoteUserID: rec.remoteUserID, botID: rec.botID) {
                $0.botName = value; $0.currentStep = nextMissingStep($0)
                if $0.currentStep == "confirm" { $0.setupStatus = "confirming" }
            }
            return .reply(currentPrompt(toolLabel: toolLabel, record: next), resetSession: false)

        case "user_title":
            let checked = validateField(text, name: "称呼", limit: 40)
            guard let value = checked.value else {
                return .reply(checked.message, resetSession: false)
            }
            let next = RemoteBotProfileStore.update(platform: rec.platform, remoteUserID: rec.remoteUserID, botID: rec.botID) {
                $0.userTitle = value; $0.currentStep = nextMissingStep($0)
                if $0.currentStep == "confirm" { $0.setupStatus = "confirming" }
            }
            return .reply(currentPrompt(toolLabel: toolLabel, record: next), resetSession: false)

        case "response_style":
            let checked = validateField(text, name: "说话风格", limit: 120)
            guard let value = checked.value else {
                return .reply(checked.message, resetSession: false)
            }
            let next = RemoteBotProfileStore.update(platform: rec.platform, remoteUserID: rec.remoteUserID, botID: rec.botID) {
                $0.responseStyle = value; $0.currentStep = "confirm"; $0.setupStatus = "confirming"
            }
            return .reply(currentPrompt(toolLabel: toolLabel, record: next), resetSession: false)

        case "confirm":
            if text == "1" {
                let next = RemoteBotProfileStore.update(platform: rec.platform, remoteUserID: rec.remoteUserID, botID: rec.botID) {
                    $0.setupStatus = "completed"; $0.currentStep = ""; $0.setupMode = ""
                }
                return .reply("✅ 设置已保存。\n\n" + profileText(next), resetSession: true)
            }
            if text == "2" {
                let next = start(platform: rec.platform, remoteUserID: rec.remoteUserID, botID: rec.botID)
                return .reply(intro(toolLabel: toolLabel, record: next), resetSession: true)
            }
            return .reply("""
            🔢 请输入数字：

            1️⃣ 确认保存
            2️⃣ 重新设置
            """, resetSession: false)

        default:
            let next = start(platform: rec.platform, remoteUserID: rec.remoteUserID, botID: rec.botID)
            return .reply(intro(toolLabel: toolLabel, record: next), resetSession: true)
        }
    }

    private static func intro(toolLabel: String, record: RemoteBotProfileRecord) -> String {
        """
        ✨ 欢迎使用这个 \(toolLabel) Bot

        使用前需要先完成个性化设置，让我知道怎么称呼您、我叫什么、说话应该是什么风格。

        🧭 请选择设置方式：
        1️⃣ 一步步设置
        2️⃣ 用一段话快速设置

        💡 如果选择 2，可以直接这样说：
        “你叫德全，称呼我为主公，说话恭敬一点，但不要太啰嗦。”
        """
    }

    private static func blockedIntro(toolLabel: String, record: RemoteBotProfileRecord) -> String {
        "⚙️ 当前 Bot 尚未完成设置，请先完成个性化设置后再使用。\n\n" + intro(toolLabel: toolLabel, record: record)
    }

    private static func currentPrompt(toolLabel: String, record rec: RemoteBotProfileRecord) -> String {
        switch rec.currentStep {
        case "mode":
            return intro(toolLabel: toolLabel, record: rec)
        case "quick_description":
            return """
            📝 请用一段话描述您希望如何设置这个 Bot。

            💡 例如：
            “你叫德全，称呼我为主公，说话恭敬一点，但不要太啰嗦。”
            """
        case "bot_name":
            if rec.setupMode == "quick" { return "🏷️ 还差一个设置：请给这个 Bot 起一个名字。" }
            return "🏷️ 请给这个 Bot 起一个名字。"
        case "user_title":
            if rec.setupMode == "quick" { return "🙋 还差一个设置：请问 Bot 应该怎么称呼您？" }
            return """
            🙋 请设置 Bot 对您的称呼。

            💡 例如：老板、主人、主公、张总、小李。
            """
        case "response_style":
            if rec.setupMode == "quick" { return "🎭 还差一个设置：请设置 Bot 的说话风格。" }
            return """
            🎭 请设置 Bot 的说话风格。

            💡 例如：正常、简洁专业、温柔耐心、古风恭敬。
            """
        case "confirm":
            return """
            ✅ 请确认当前设置：

            🏷️ Bot 名字：\(rec.botName)
            🙋 对您的称呼：\(rec.userTitle)
            🎭 说话风格：\(rec.responseStyle.isEmpty ? defaultStyle : rec.responseStyle)

            回复：
            1️⃣ 确认保存
            2️⃣ 重新设置
            """
        default:
            return intro(toolLabel: toolLabel, record: rec)
        }
    }

    private static func profileText(_ rec: RemoteBotProfileRecord) -> String {
        """
        📋 当前 Bot 设置：

        🏷️ Bot 名字：\(rec.botName)
        🙋 对您的称呼：\(rec.userTitle)
        🎭 说话风格：\(rec.responseStyle.isEmpty ? defaultStyle : rec.responseStyle)
        """
    }

    private static func decoratePrompt(_ prompt: String, profile rec: RemoteBotProfileRecord) -> String {
        """
        请按以下个性化设置回复当前远程用户：
        - 你的名字：\(rec.botName)
        - 对用户称呼：\(rec.userTitle)
        - 说话风格：\(rec.responseStyle.isEmpty ? defaultStyle : rec.responseStyle)

        用户消息：
        \(prompt)
        """
    }

    private static func nextMissingStep(_ rec: RemoteBotProfileRecord) -> String {
        if rec.botName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return "bot_name" }
        if rec.userTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return "user_title" }
        if rec.responseStyle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return "response_style" }
        return "confirm"
    }

    private static func validateField(_ text: String, name: String, limit: Int) -> (value: String?, message: String) {
        let value = normalized(text)
        guard !value.isEmpty else { return (nil, "⚠️ \(name)不能为空，请重新输入。") }
        if value.count > limit { return (nil, "⚠️ \(name)内容过长，请重说。") }
        if value.hasPrefix("/") { return (nil, "⚠️ \(name)不符合项目规则，请重说。") }
        return (value, "")
    }

    private static func normalized(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
            .split(whereSeparator: { $0.isWhitespace || $0.isNewline })
            .joined(separator: " ")
    }

    private struct QuickConfig {
        var botName: String?
        var userTitle: String?
        var responseStyle: String?
    }

    private static func extractQuickConfig(from text: String) -> QuickConfig? {
        let raw = normalized(text)
        guard !raw.isEmpty, raw.count <= 500 else { return nil }
        var result = QuickConfig()
        result.botName = firstMatch(in: raw, patterns: ["你叫", "名字叫", "以后叫"])
        result.userTitle = firstMatch(in: raw, patterns: ["称呼我为", "叫我", "喊我", "称呼我", "对我称呼为"])
        if let style = firstMatch(in: raw, patterns: ["说话", "风格", "语气"]) {
            result.responseStyle = style
        } else if raw.contains("正常") {
            result.responseStyle = defaultStyle
        }
        let hasAny = result.botName != nil || result.userTitle != nil || result.responseStyle != nil
        return hasAny ? result : nil
    }

    private static func firstMatch(in text: String, patterns: [String]) -> String? {
        for p in patterns {
            guard let range = text.range(of: p) else { continue }
            var tail = String(text[range.upperBound...])
            tail = tail.trimmingCharacters(in: .whitespacesAndNewlines)
            if tail.hasPrefix("：") || tail.hasPrefix(":") { tail.removeFirst() }
            let separators = CharacterSet(charactersIn: "，,。.;；\n")
            let head = tail.components(separatedBy: separators).first ?? tail
            let cleaned = normalized(head)
                .trimmingCharacters(in: CharacterSet(charactersIn: "“”\"' "))
            if !cleaned.isEmpty, cleaned.count <= 120 { return cleaned }
        }
        return nil
    }
}

/// Telegram 文件落地后的任务目录。每条文件消息新建一份任务,只把当前任务 outbox 里的普通文件自动回传。
struct RemoteFileTask {
    struct InputFile {
        let sourceKind: String
        let fileID: String
        let originalName: String
        let storedName: String
        let path: String
        let size: Int?
        let mimeType: String?
    }

    let platform: String
    let botID: String
    let remoteUserID: String
    let taskID: String
    let createdAt: Date
    let root: URL
    let inbox: URL
    let work: URL
    let outbox: URL
    let meta: URL

    /// 远程文件任务根目录:Application Support 下,与 monitor / profiles 同处 com.agent.pet 一棵树。
    /// create / latestExisting / cleanup 共用此单点。
    static func defaultBaseDirectory() -> URL {
        URL(fileURLWithPath: RemoteBotProfileStore.dataDirectory, isDirectory: true)
            .appendingPathComponent("remote-files", isDirectory: true)
    }

    /// 旧版根目录(home 根下的可见目录)。仅供启动迁移把历史任务搬到新位置,新代码不再往这里写。
    static func legacyBaseDirectory() -> URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("AgentPetRemoteFiles", isDirectory: true)
    }

    /// 把旧版 ~/AgentPetRemoteFiles 的历史任务迁到新位置。幂等:旧目录不在即跳过,可反复调用。
    /// 新位置整个不存在 → 整目录搬过去(同卷为原子 rename,快);新位置已存在 → 逐任务合并搬,再清掉旧空壳。
    /// 默认走真实路径;自测传 oldBase/newBase 用临时目录,绝不碰主公真实文件。返回迁移任务数(整目录搬记 1)。
    @discardableResult
    static func migrateLegacyBaseIfNeeded(oldBase: URL? = nil, newBase: URL? = nil) -> Int {
        let fm = FileManager.default
        let oldBase = oldBase ?? legacyBaseDirectory()
        let newBase = newBase ?? defaultBaseDirectory()
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: oldBase.path, isDirectory: &isDir), isDir.boolValue else { return 0 }

        // 新位置整个不存在:直接把旧目录搬成新目录,一步到位、保留全部子结构。
        if !fm.fileExists(atPath: newBase.path) {
            do {
                try fm.createDirectory(at: newBase.deletingLastPathComponent(), withIntermediateDirectories: true)
                try fm.moveItem(at: oldBase, to: newBase)
                PetView.log("远程文件目录迁移:\(oldBase.path) → \(newBase.path)(整目录搬迁)")
                return 1
            } catch {
                PetView.log("远程文件目录迁移失败(整目录):\(error.localizedDescription)")
                return 0
            }
        }

        // 新位置已存在:逐个任务合并搬,保留各自 平台/bot/user/日期 相对路径;任务名含时间+uuid,几乎不撞。
        guard let enumerator = fm.enumerator(at: oldBase, includingPropertiesForKeys: nil) else { return 0 }
        var taskRoots: [URL] = []
        for case let url as URL in enumerator where url.lastPathComponent == "meta.json" {
            taskRoots.append(url.deletingLastPathComponent())
        }
        // enumerator 返回的 URL 会解析符号链接(如 /var → /private/var),oldBase 可能未解析,直接字符串剥前缀会错位、
        // 算出带 /private 的相对路径把任务搬到错位置。故两端统一 resolvingSymlinksInPath 后按路径组件相对化。
        let oldComponents = oldBase.resolvingSymlinksInPath().pathComponents
        var moved = 0
        for taskRoot in taskRoots {
            let relComponents = Array(taskRoot.resolvingSymlinksInPath().pathComponents.dropFirst(oldComponents.count))
            guard !relComponents.isEmpty else { continue }
            var dest = relComponents.reduce(newBase) { $0.appendingPathComponent($1, isDirectory: true) }
            if fm.fileExists(atPath: dest.path) {   // 极罕见撞名:加 uuid 后缀,绝不覆盖
                dest = dest.deletingLastPathComponent()
                    .appendingPathComponent(dest.lastPathComponent + "-" + String(UUID().uuidString.prefix(4)), isDirectory: true)
            }
            do {
                try fm.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
                try fm.moveItem(at: taskRoot, to: dest)
                moved += 1
            } catch {
                PetView.log("远程文件目录迁移失败(任务 \(taskRoot.lastPathComponent)):\(error.localizedDescription)")
            }
        }
        pruneEmptyDirectories(oldBase)
        if let rest = try? fm.contentsOfDirectory(atPath: oldBase.path), rest.isEmpty {
            try? fm.removeItem(at: oldBase)   // 旧 base 已全空,连根删掉免得 home 留空壳
        }
        if moved > 0 { PetView.log("远程文件目录迁移:合并搬迁 \(moved) 个历史任务到 \(newBase.path)") }
        return moved
    }

    /// 把旧的「按 年/月/日 分桶」历史任务(平台/bot/用户/yyyy/MM/dd/任务)拍平成 平台/bot/用户/任务,
    /// 并洗掉 meta 里残留的绝对路径。幂等:已扁平的只洗一次 meta、不挪动。返回处理过的任务数。
    /// 判定:任务相对 base >4 段即夹着日期壳,拍平到 前3段 + taskID(末段)。默认走真实 base,自测传临时 base。
    @discardableResult
    static func migrateFlattenDateBucketsIfNeeded(base: URL? = nil) -> Int {
        let fm = FileManager.default
        let base = base ?? defaultBaseDirectory()
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: base.path, isDirectory: &isDir), isDir.boolValue,
              let enumerator = fm.enumerator(at: base, includingPropertiesForKeys: nil) else { return 0 }
        var taskRoots: [URL] = []
        for case let url as URL in enumerator where url.lastPathComponent == "meta.json" {
            taskRoots.append(url.deletingLastPathComponent())
        }
        // 两端统一 resolvingSymlinksInPath 再剥前缀,避免 /var↔/private/var 错位(同 migrateLegacyBaseIfNeeded 的坑)。
        let baseComponents = base.resolvingSymlinksInPath().pathComponents
        var processed = 0
        for taskRoot in taskRoots {
            let rel = Array(taskRoot.resolvingSymlinksInPath().pathComponents.dropFirst(baseComponents.count))
            guard rel.count >= 4 else { continue }   // 不足 平台/bot/用户/任务 4 段,非正常任务,跳过
            let moved = rel.count > 4
            var finalRoot = taskRoot
            if moved {
                // 扁平目标:平台/bot/用户(前 3 段)+ 任务(末段),中间的 年/月/日 壳全丢。
                let flat = [rel[0], rel[1], rel[2], rel[rel.count - 1]]
                var dest = flat.reduce(base) { $0.appendingPathComponent($1, isDirectory: true) }
                if fm.fileExists(atPath: dest.path) {   // 极罕见撞名:加 uuid 后缀,绝不覆盖
                    dest = dest.deletingLastPathComponent()
                        .appendingPathComponent(dest.lastPathComponent + "-" + String(UUID().uuidString.prefix(4)), isDirectory: true)
                }
                do {
                    try fm.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try fm.moveItem(at: taskRoot, to: dest)
                    finalRoot = dest
                } catch {
                    PetView.log("远程文件扁平化失败(任务 \(taskRoot.lastPathComponent)):\(error.localizedDescription)")
                    continue
                }
            }
            let metaCleaned = stripLegacyPathsFromMeta(finalRoot.appendingPathComponent("meta.json"))
            if moved || metaCleaned { processed += 1 }
        }
        pruneEmptyDirectories(base)
        if processed > 0 { PetView.log("远程文件目录扁平化:处理 \(processed) 个历史任务(去日期壳 / 洗 meta 旧路径)") }
        return processed
    }

    /// 删掉 meta.json 里冗余的绝对路径字段(root/inbox/work/outbox 及每个 file 的 path)。
    /// 新版 writeMeta 已不写这些,这里负责把存量旧 meta 洗干净。返回是否实际改动过(无冗余则不重写)。
    @discardableResult
    static func stripLegacyPathsFromMeta(_ metaURL: URL) -> Bool {
        guard let data = try? Data(contentsOf: metaURL),
              var obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return false }
        var changed = false
        for key in ["root", "inbox", "work", "outbox"] where obj[key] != nil {
            obj.removeValue(forKey: key); changed = true
        }
        if var files = obj["files"] as? [[String: Any]] {
            var fileChanged = false
            for i in files.indices where files[i]["path"] != nil {
                files[i].removeValue(forKey: "path"); fileChanged = true
            }
            if fileChanged { obj["files"] = files; changed = true }
        }
        guard changed,
              let out = try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys]) else { return changed }
        try? out.write(to: metaURL, options: .atomic)
        return true
    }

    static func create(platform: String, botID: String, remoteUserID: String, now: Date = Date(),
                       baseDirectory: URL? = nil) throws -> RemoteFileTask {
        let safePlatform = sanitizePathSegment(platform, fallback: "platform")
        let safeBot = sanitizePathSegment(botID, fallback: "bot")
        let safeUser = sanitizePathSegment(remoteUserID, fallback: "user")
        // 任务目录直挂 平台/bot/用户/任务,不再按 年/月/日 分桶:taskID 自带 yyyyMMdd-HHmmss、日期信息不丢,省掉三层冗余深度与空壳。
        let taskID = makeTaskID(date: now)
        let base = baseDirectory ?? defaultBaseDirectory()
        let root = base
            .appendingPathComponent(safePlatform, isDirectory: true)
            .appendingPathComponent(safeBot, isDirectory: true)
            .appendingPathComponent(safeUser, isDirectory: true)
            .appendingPathComponent(taskID, isDirectory: true)
        let inbox = root.appendingPathComponent("inbox", isDirectory: true)
        let work = root.appendingPathComponent("work", isDirectory: true)
        let outbox = root.appendingPathComponent("outbox", isDirectory: true)
        for dir in [inbox, work, outbox] {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        return RemoteFileTask(platform: safePlatform, botID: safeBot, remoteUserID: safeUser,
                              taskID: taskID, createdAt: now, root: root, inbox: inbox,
                              work: work, outbox: outbox, meta: root.appendingPathComponent("meta.json"))
    }

    static func load(root: URL, platform: String, botID: String, remoteUserID: String) -> RemoteFileTask? {
        let meta = root.appendingPathComponent("meta.json", isDirectory: false)
        let inbox = root.appendingPathComponent("inbox", isDirectory: true)
        let work = root.appendingPathComponent("work", isDirectory: true)
        let outbox = root.appendingPathComponent("outbox", isDirectory: true)
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: root.path, isDirectory: &isDir), isDir.boolValue,
              FileManager.default.fileExists(atPath: meta.path),
              FileManager.default.fileExists(atPath: inbox.path, isDirectory: &isDir), isDir.boolValue,
              FileManager.default.fileExists(atPath: work.path, isDirectory: &isDir), isDir.boolValue,
              FileManager.default.fileExists(atPath: outbox.path, isDirectory: &isDir), isDir.boolValue else { return nil }
        let createdAt = ((try? meta.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate) ?? Date.distantPast
        return RemoteFileTask(platform: sanitizePathSegment(platform, fallback: "platform"),
                              botID: sanitizePathSegment(botID, fallback: "bot"),
                              remoteUserID: sanitizePathSegment(remoteUserID, fallback: "user"),
                              taskID: root.lastPathComponent, createdAt: createdAt, root: root,
                              inbox: inbox, work: work, outbox: outbox, meta: meta)
    }

    static func latestExisting(platform: String, botID: String, remoteUserID: String,
                               baseDirectory: URL? = nil) -> RemoteFileTask? {
        let safePlatform = sanitizePathSegment(platform, fallback: "platform")
        let safeBot = sanitizePathSegment(botID, fallback: "bot")
        let safeUser = sanitizePathSegment(remoteUserID, fallback: "user")
        let base = baseDirectory ?? defaultBaseDirectory()
        let userRoot = base
            .appendingPathComponent(safePlatform, isDirectory: true)
            .appendingPathComponent(safeBot, isDirectory: true)
            .appendingPathComponent(safeUser, isDirectory: true)
        guard let enumerator = FileManager.default.enumerator(at: userRoot, includingPropertiesForKeys: nil) else { return nil }
        var roots: [URL] = []
        for case let url as URL in enumerator where url.lastPathComponent == "meta.json" {
            roots.append(url.deletingLastPathComponent())
        }
        guard let latestRoot = roots.max(by: { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }) else {
            return nil
        }
        return load(root: latestRoot, platform: safePlatform, botID: safeBot, remoteUserID: safeUser)
    }

    static func sanitizePathSegment(_ raw: String, fallback: String) -> String {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_")
        let cleaned = raw.unicodeScalars.map { allowed.contains($0) ? Character($0) : "_" }
        let value = String(cleaned).trimmingCharacters(in: CharacterSet(charactersIn: "._-"))
        return value.isEmpty ? fallback : String(value.prefix(80))
    }

    static func sanitizeFileName(_ raw: String, fallback: String) -> String {
        let last = URL(fileURLWithPath: raw).lastPathComponent
        var cleaned = last.replacingOccurrences(of: "\u{0}", with: "_")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "\\", with: "_")
            .replacingOccurrences(of: ":", with: "_")
            .replacingOccurrences(of: "..", with: "_")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        while cleaned.hasPrefix(".") { cleaned.removeFirst() }
        if cleaned.isEmpty { cleaned = fallback }
        return String(cleaned.prefix(160))
    }

    func reserveInboxURL(fileName: String) -> URL {
        let safe = Self.sanitizeFileName(fileName, fallback: "telegram-file")
        var candidate = inbox.appendingPathComponent(safe, isDirectory: false)
        guard FileManager.default.fileExists(atPath: candidate.path) else { return candidate }
        let base = (safe as NSString).deletingPathExtension
        let ext = (safe as NSString).pathExtension
        for idx in 2...999 {
            let name = ext.isEmpty ? "\(base)-\(idx)" : "\(base)-\(idx).\(ext)"
            candidate = inbox.appendingPathComponent(name, isDirectory: false)
            if !FileManager.default.fileExists(atPath: candidate.path) { return candidate }
        }
        return inbox.appendingPathComponent(UUID().uuidString + "-" + safe, isDirectory: false)
    }

    func writeMeta(chatID: String, senderName: String, toolLabel: String, requestText: String,
                   files: [InputFile]) throws {
        let iso = ISO8601DateFormatter()
        // meta 只记逻辑元数据,不落 root/inbox/work/outbox/file.path 等绝对路径:这些全可由任务目录推导
        // (root = meta 所在目录,inbox/work/outbox 是固定子目录,文件即 inbox/<storedName>),
        // 落了反成搬目录后唯一会失准的字段。storedName 即 inbox 内文件名,足够定位。
        let filePayload: [[String: Any]] = files.map { f in
            var item: [String: Any] = [
                "sourceKind": f.sourceKind,
                "fileID": f.fileID,
                "originalName": f.originalName,
                "storedName": f.storedName,
            ]
            if let size = f.size { item["size"] = size }
            if let mimeType = f.mimeType { item["mimeType"] = mimeType }
            return item
        }
        let payload: [String: Any] = [
            "platform": platform,
            "botID": botID,
            "remoteUserID": remoteUserID,
            "chatID": chatID,
            "senderName": senderName,
            "tool": toolLabel,
            "taskID": taskID,
            "createdAt": iso.string(from: createdAt),
            "requestText": requestText,
            "files": filePayload,
        ]
        let data = try JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: meta, options: .atomic)
    }

    func prompt(userRequest: String, files: [InputFile]) -> String {
        let listed = files.map { "- \($0.storedName)（\($0.sourceKind)，内部路径：\($0.path)）" }.joined(separator: "\n")
        let request = userRequest.trimmingCharacters(in: .whitespacesAndNewlines)
        let finalRequest = request.isEmpty ? "用户只上传了文件,没有附加处理要求。请先检查文件并回复你已收到哪些文件,再请用户补充要怎么处理。没有明确要求时不要改写原始文件。" : request
        return """
        本次 Telegram 文件任务目录：
        \(root.path)

        收到的原始文件只能读取这里：
        \(inbox.path)

        处理中间文件请放这里：
        \(work.path)

        需要回传给 Telegram 的最终文件必须放这里：
        \(outbox.path)

        只允许把需要发回用户的最终文件放入 outbox。不要把 inbox 原始文件直接挪走；如需修改,请复制到 work 或 outbox 后再处理。

        回复用户时必须简洁。不要展示任务目录、内部路径、命令过程、调试细节或大段处理步骤；只说明处理结果、是否已生成/回传文件、必要的下一步或错误原因。

        本次收到的文件：
        \(listed.isEmpty ? "（无）" : listed)

        用户要求：
        \(finalRequest)
        """
    }

    func followUpPrompt(userRequest: String) -> String {
        let outputs = outboxFiles().map { "- \($0.lastPathComponent)（内部路径：\($0.path)）" }.joined(separator: "\n")
        return """
        这是 Telegram 文件任务的后续修改。用户没有重新上传文件,请继续使用上一轮任务目录里的文件。

        任务目录：
        \(root.path)

        原始文件在：
        \(inbox.path)

        上一轮处理结果在：
        \(outbox.path)

        中间文件在：
        \(work.path)

        如果 outbox 里已有上一轮结果,优先基于上一轮结果继续修改；否则基于 inbox 原始文件处理。新的最终结果仍必须放入 outbox。
        如果用户只是询问是否处理完成、结果在哪里、有没有生成,请检查 outbox 是否已有结果文件并简短回答；不要要求用户重新上传。

        当前 outbox 文件：
        \(outputs.isEmpty ? "（暂无）" : outputs)

        回复用户时必须简洁。不要展示任务目录、内部路径、命令过程、调试细节或大段处理步骤；只说明处理结果、是否已生成/回传文件、必要的下一步或错误原因。

        用户这次的新要求：
        \(userRequest)
        """
    }

    func outboxFiles() -> [URL] {
        guard let urls = try? FileManager.default.contentsOfDirectory(at: outbox, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles]) else {
            return []
        }
        return urls.filter { url in
            let values = try? url.resourceValues(forKeys: [.isRegularFileKey])
            return values?.isRegularFile == true
        }.sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
    }

    // MARK: 清理 —— 任务目录永不回收会吃满磁盘,这里按"保留天数 + 总容量上限"定期回收旧任务

    /// 清理节流:进程内记上次真扫时刻,默认 6 小时一轮,避免每条文件消息都全盘扫。NSLock 保任意线程可调。
    private static let cleanupLock = NSLock()
    private static var lastCleanupAt: Date?

    /// 机会式清理:启动时(force=true)与每次新建任务后调用;非 force 时按 6 小时节流决定是否真扫。
    /// 阈值读 Settings(保留天数 / 总容量 MB),≤0 表示对应维度不限。只有真删了才记日志。
    static func maybeCleanup(force: Bool = false, now: Date = Date()) {
        cleanupLock.lock()
        if !force, let last = lastCleanupAt, now.timeIntervalSince(last) < 6 * 3600 {
            cleanupLock.unlock()
            return
        }
        lastCleanupAt = now
        cleanupLock.unlock()
        let maxMB = Settings.remoteFileMaxTotalMB
        let maxBytes = maxMB > 0 ? Int64(maxMB) * 1024 * 1024 : 0
        let result = cleanup(retentionDays: Settings.remoteFileRetentionDays, maxTotalBytes: maxBytes, now: now)
        if result.removed > 0 {
            PetView.log("远程文件清理:回收 \(result.removed) 个任务目录,释放约 \(result.freedBytes / 1024 / 1024) MB")
        }
    }

    /// 实际清理:先按保留天数删超期任务,再按总容量上限从最旧往新删到阈值内,最后清掉清空后的空壳目录。
    /// retentionDays ≤ 0 跳过按天清理;maxTotalBytes ≤ 0 跳过按容量清理。返回删除任务数与释放字节,供日志/自测核对。
    @discardableResult
    static func cleanup(retentionDays: Int, maxTotalBytes: Int64, now: Date = Date(),
                        baseDirectory: URL? = nil) -> (removed: Int, freedBytes: Int64) {
        let base = baseDirectory ?? defaultBaseDirectory()
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: base.path, isDirectory: &isDir), isDir.boolValue,
              let enumerator = fm.enumerator(at: base, includingPropertiesForKeys: nil) else { return (0, 0) }

        struct Item { let root: URL; let activity: Date; let size: Int64 }
        var items: [Item] = []
        for case let url as URL in enumerator where url.lastPathComponent == "meta.json" {
            let root = url.deletingLastPathComponent()
            let stats = taskStats(root)
            items.append(Item(root: root, activity: stats.activity, size: stats.size))
        }

        var removed = 0
        var freed: Int64 = 0
        var survivors: [Item] = []
        if retentionDays > 0 {
            let cutoff = now.addingTimeInterval(-Double(retentionDays) * 86_400)
            for item in items {
                if item.activity < cutoff, (try? fm.removeItem(at: item.root)) != nil {
                    removed += 1; freed += item.size
                } else {
                    survivors.append(item)
                }
            }
        } else {
            survivors = items
        }

        if maxTotalBytes > 0 {
            var total = survivors.reduce(Int64(0)) { $0 + $1.size }
            if total > maxTotalBytes {
                for item in survivors.sorted(by: { $0.activity < $1.activity }) {
                    if total <= maxTotalBytes { break }
                    if (try? fm.removeItem(at: item.root)) != nil {
                        removed += 1; freed += item.size; total -= item.size
                    }
                }
            }
        }

        pruneEmptyDirectories(base)
        return (removed, freed)
    }

    /// 一次遍历得出任务目录的占用字节与"最后活动时间"(目录树内最新文件 mtime,兜底用目录自身 mtime)。
    /// 用最新活动而非创建时间,避免把刚被续接、outbox 刚生成结果的任务误判为过期。
    private static func taskStats(_ root: URL) -> (size: Int64, activity: Date) {
        let fm = FileManager.default
        var size: Int64 = 0
        var latest = (try? root.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? Date.distantPast
        if let e = fm.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey]) {
            for case let url as URL in e {
                let v = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey])
                if v?.isRegularFile == true { size += Int64(v?.fileSize ?? 0) }
                if let m = v?.contentModificationDate, m > latest { latest = m }
            }
        }
        return (size, latest)
    }

    /// 删除清空后剩下的上层空目录(日期壳 / user / bot / platform),避免清完任务留一堆空文件夹。base 本身保留。
    private static func pruneEmptyDirectories(_ base: URL) {
        let fm = FileManager.default
        guard let e = fm.enumerator(at: base, includingPropertiesForKeys: [.isDirectoryKey]) else { return }
        var dirs: [URL] = []
        for case let url as URL in e {
            if (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true { dirs.append(url) }
        }
        // 深的先删:子目录清空后上层才会跟着变空
        for dir in dirs.sorted(by: { $0.pathComponents.count > $1.pathComponents.count }) {
            if let contents = try? fm.contentsOfDirectory(atPath: dir.path), contents.isEmpty {
                try? fm.removeItem(at: dir)
            }
        }
    }

    /// 清理逻辑离线自测:临时目录造"超期/近期/超量"任务,核对按天删旧留新、按容量删最旧、阈值≤0 跳过、空壳回收。
    static func runCleanupSelfTest() -> Bool {
        let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("agentpet-file-cleanup-dryrun-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let fm = FileManager.default
        let now = Date(timeIntervalSince1970: 1_782_066_615)

        func makeTask(in base: URL, ageDays: Double, bytes: Int, label: String) throws -> RemoteFileTask {
            let created = now.addingTimeInterval(-ageDays * 86_400)
            let t = try create(platform: "telegram", botID: "cc-bot1", remoteUserID: "u1", now: created, baseDirectory: base)
            try Data(repeating: 0x41, count: bytes).write(to: t.inbox.appendingPathComponent("\(label).bin"))
            try t.writeMeta(chatID: "u1", senderName: "主公", toolLabel: "cc/claude", requestText: label, files: [])
            // 把整棵任务树 mtime 回拨到对应年龄,让 taskStats 的"最后活动时间"命中按天清理
            try fm.setAttributes([.modificationDate: created], ofItemAtPath: t.root.path)
            if let e = fm.enumerator(at: t.root, includingPropertiesForKeys: nil) {
                for case let url as URL in e { try? fm.setAttributes([.modificationDate: created], ofItemAtPath: url.path) }
            }
            return t
        }

        do {
            // 场景一:按天保留 14 天 —— 20 天前删、1 天前留
            let baseA = root.appendingPathComponent("by-age", isDirectory: true)
            let old = try makeTask(in: baseA, ageDays: 20, bytes: 1_000, label: "old")
            let recent = try makeTask(in: baseA, ageDays: 1, bytes: 1_000, label: "recent")
            let r1 = cleanup(retentionDays: 14, maxTotalBytes: 0, now: now, baseDirectory: baseA)
            let s1 = !fm.fileExists(atPath: old.root.path) && fm.fileExists(atPath: recent.root.path) && r1.removed == 1

            // 场景二:按容量上限从最旧删 —— 三个各 100KB 共 300KB,上限 250KB,删最旧 a 后剩 200KB 达标
            let baseB = root.appendingPathComponent("by-size", isDirectory: true)
            let a = try makeTask(in: baseB, ageDays: 3, bytes: 100_000, label: "a")
            let b = try makeTask(in: baseB, ageDays: 2, bytes: 100_000, label: "b")
            let c = try makeTask(in: baseB, ageDays: 1, bytes: 100_000, label: "c")
            let r2 = cleanup(retentionDays: 0, maxTotalBytes: 250_000, now: now, baseDirectory: baseB)
            let s2 = !fm.fileExists(atPath: a.root.path) && fm.fileExists(atPath: b.root.path)
                && fm.fileExists(atPath: c.root.path) && r2.removed == 1
            // 场景四:空壳回收 —— 扁平结构下单任务删除后,其上层 平台/bot/用户 空壳应被清掉、base 自身保留。
            // (不能复用场景二的 a:扁平后 a/b/c 共享同一个用户目录,删 a 后父目录仍有 b/c、本就不该回收。)
            let baseE = root.appendingPathComponent("prune", isDirectory: true)
            let solo = try makeTask(in: baseE, ageDays: 1, bytes: 1_000, label: "solo")
            try fm.removeItem(at: solo.root)            // 模拟任务被清,只剩空的 平台/bot/用户 壳
            pruneEmptyDirectories(baseE)
            let s4 = !fm.fileExists(atPath: solo.root.deletingLastPathComponent().path)   // 用户壳已回收
                && fm.fileExists(atPath: baseE.path)                                       // base 自身保留

            // 场景三:阈值都 ≤0 —— 什么都不删
            let baseC = root.appendingPathComponent("disabled", isDirectory: true)
            let keep = try makeTask(in: baseC, ageDays: 99, bytes: 1_000, label: "keep")
            let r3 = cleanup(retentionDays: 0, maxTotalBytes: 0, now: now, baseDirectory: baseC)
            let s3 = fm.fileExists(atPath: keep.root.path) && r3.removed == 0

            // 场景五:旧目录迁移 —— 新位置不存在时整目录搬迁,任务原样落到新位置,旧目录搬空后删除
            let oldB = root.appendingPathComponent("legacy", isDirectory: true)
            let newB = root.appendingPathComponent("appsupport/remote-files", isDirectory: true)
            let legacyTask = try makeTask(in: oldB, ageDays: 1, bytes: 1_000, label: "legacy")
            let relLegacy = legacyTask.root.path.replacingOccurrences(of: oldB.path + "/", with: "")
            let n1 = migrateLegacyBaseIfNeeded(oldBase: oldB, newBase: newB)
            let s5 = n1 == 1 && fm.fileExists(atPath: newB.appendingPathComponent(relLegacy).path)
                && !fm.fileExists(atPath: oldB.path)

            // 场景六:新位置已存在 —— 逐任务合并搬,旧任务进新位置且原有任务不受影响
            let oldB2 = root.appendingPathComponent("legacy2", isDirectory: true)
            let newB2 = root.appendingPathComponent("appsupport2/remote-files", isDirectory: true)
            let existed = try makeTask(in: newB2, ageDays: 1, bytes: 1_000, label: "existed")
            let toMigrate = try makeTask(in: oldB2, ageDays: 1, bytes: 1_000, label: "tomigrate")
            let relMig = toMigrate.root.path.replacingOccurrences(of: oldB2.path + "/", with: "")
            let n2 = migrateLegacyBaseIfNeeded(oldBase: oldB2, newBase: newB2)
            let s6 = n2 == 1 && fm.fileExists(atPath: newB2.appendingPathComponent(relMig).path)
                && fm.fileExists(atPath: existed.root.path)

            // 场景七:日期分桶拍平 —— 手造 平台/bot/用户/yyyy/MM/dd/任务 旧结构 + meta 残留绝对路径,
            // 扁平化后应搬到 平台/bot/用户/任务、日期空壳被回收、meta 里 root/inbox/work/outbox/file.path 全洗掉、逻辑字段保留。
            let baseD = root.appendingPathComponent("flatten/remote-files", isDirectory: true)
            let dated = baseD.appendingPathComponent("telegram/cc-bot1/u1/2026/06/22/20260622-101010-aaaa", isDirectory: true)
            try fm.createDirectory(at: dated.appendingPathComponent("inbox", isDirectory: true), withIntermediateDirectories: true)
            try fm.createDirectory(at: dated.appendingPathComponent("outbox", isDirectory: true), withIntermediateDirectories: true)
            try Data("x".utf8).write(to: dated.appendingPathComponent("inbox/a.txt"))
            let legacyMeta: [String: Any] = ["taskID": "20260622-101010-aaaa", "platform": "telegram",
                "root": "/old/abs", "inbox": "/old/abs/inbox", "work": "/old/abs/work", "outbox": "/old/abs/outbox",
                "files": [["storedName": "a.txt", "path": "/old/abs/inbox/a.txt"]]]
            try JSONSerialization.data(withJSONObject: legacyMeta, options: [.prettyPrinted])
                .write(to: dated.appendingPathComponent("meta.json"))
            let n3 = migrateFlattenDateBucketsIfNeeded(base: baseD)
            let flatRoot = baseD.appendingPathComponent("telegram/cc-bot1/u1/20260622-101010-aaaa", isDirectory: true)
            let metaAfter = (try? String(contentsOf: flatRoot.appendingPathComponent("meta.json"), encoding: .utf8)) ?? ""
            let s7 = n3 == 1
                && fm.fileExists(atPath: flatRoot.appendingPathComponent("inbox/a.txt").path)
                && !fm.fileExists(atPath: baseD.appendingPathComponent("telegram/cc-bot1/u1/2026").path)
                && !metaAfter.contains("/old/abs") && !metaAfter.contains("\"root\"") && !metaAfter.contains("\"inbox\"")
                && metaAfter.contains("\"taskID\"")

            let ok = s1 && s2 && s3 && s4 && s5 && s6 && s7
            print("远程文件清理/迁移 dryrun:")
            print("  场景一 按天保留: \(s1 ? "PASS" : "FAIL") (removed=\(r1.removed))")
            print("  场景二 容量删旧: \(s2 ? "PASS" : "FAIL") (removed=\(r2.removed))")
            print("  场景三 阈值关闭: \(s3 ? "PASS" : "FAIL") (removed=\(r3.removed))")
            print("  场景四 空壳回收: \(s4 ? "PASS" : "FAIL")")
            print("  场景五 整目录迁移: \(s5 ? "PASS" : "FAIL") (moved=\(n1))")
            print("  场景六 合并迁移: \(s6 ? "PASS" : "FAIL") (moved=\(n2))")
            print("  场景七 日期拍平: \(s7 ? "PASS" : "FAIL") (processed=\(n3))")
            print("  结果:\(ok ? "PASS" : "FAIL")")
            return ok
        } catch {
            print("远程文件清理 dryrun:FAIL \(error.localizedDescription)")
            return false
        }
    }

    static func runSelfTest() -> Bool {
        let base = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("agentpet-file-task-dryrun-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: base) }
        do {
            let fixed = Date(timeIntervalSince1970: 1_782_066_615)
            let sampleRemoteUserID = "1000000000"
            let task = try create(platform: "telegram", botID: "cx-bot2", remoteUserID: sampleRemoteUserID, now: fixed, baseDirectory: base)
            let unsafe = "../.secret/report:1.txt"
            let dest = task.reserveInboxURL(fileName: unsafe)
            try Data("inbox".utf8).write(to: dest)
            let input = InputFile(sourceKind: "document", fileID: "FILE-ID", originalName: unsafe,
                                  storedName: dest.lastPathComponent, path: dest.path, size: 5, mimeType: "text/plain")
            try task.writeMeta(chatID: sampleRemoteUserID, senderName: "主公", toolLabel: "cx/codex", requestText: "处理这个文件", files: [input])
            try Data("out".utf8).write(to: task.outbox.appendingPathComponent("result.txt"))
            try FileManager.default.createDirectory(at: task.outbox.appendingPathComponent("nested", isDirectory: true),
                                                    withIntermediateDirectories: true)
            let newer = try create(platform: "telegram", botID: "cx-bot2", remoteUserID: sampleRemoteUserID,
                                   now: fixed.addingTimeInterval(60), baseDirectory: base)
            try Data("new".utf8).write(to: newer.inbox.appendingPathComponent("new.txt"))
            try newer.writeMeta(chatID: sampleRemoteUserID, senderName: "主公", toolLabel: "cx/codex", requestText: "新文件", files: [])
            let metaText = try String(contentsOf: task.meta, encoding: .utf8)
            let outbox = task.outboxFiles().map(\.lastPathComponent)
            let followUp = task.followUpPrompt(userRequest: "把刚才那个文件再整理一下")
            let latest = latestExisting(platform: "telegram", botID: "cx-bot2", remoteUserID: sampleRemoteUserID, baseDirectory: base)
            let ok = task.root.deletingLastPathComponent().lastPathComponent == sampleRemoteUserID   // 扁平:任务直挂用户目录,中间无 年/月/日 壳
                && task.root.path.contains("/telegram/cx-bot2/\(sampleRemoteUserID)/")
                && !metaText.contains("\"root\"") && !metaText.contains("\"inbox\"")   // meta 不再落绝对路径字段
                && task.inbox.lastPathComponent == "inbox"
                && task.work.lastPathComponent == "work"
                && task.outbox.lastPathComponent == "outbox"
                && !dest.lastPathComponent.contains("..")
                && !dest.lastPathComponent.hasPrefix(".")
                && metaText.contains("\"taskID\"")
                && outbox == ["result.txt"]
                && followUp.contains("后续修改")
                && followUp.contains("result.txt")
                && latest?.taskID == newer.taskID
            print("Telegram 文件任务 dryrun:")
            print("  taskRoot=\(task.root.path)")
            print("  inboxFile=\(dest.lastPathComponent)")
            print("  outboxFiles=\(outbox.joined(separator: ", "))")
            print("  meta=\(task.meta.path)")
            print("  结果:\(ok ? "PASS" : "FAIL")")
            return ok
        } catch {
            print("Telegram 文件任务 dryrun:FAIL \(error.localizedDescription)")
            return false
        }
    }

    private static func makeTaskID(date: Date) -> String {
        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US_POSIX")
        df.dateFormat = "yyyyMMdd-HHmmss"
        return df.string(from: date) + "-" + String(UUID().uuidString.prefix(4)).lowercased()
    }
}

/// 一个 Telegram bot 的轮询器:long polling 收消息 → 解析指令/喂 agent → 回话。
/// 每个实例绑定一个 token + 一个 tool(cc 或 cx);按 chat id 各建一份 ChatContext,
/// 不同用户并行、各记各的目录与上下文,同一用户串行,所以谁也不串话、谁也卡不住谁。
final class TelegramBot {
    struct FileAttachment {
        let kind: String
        let fileID: String
        let fileUniqueID: String?
        let fileName: String?
        let mimeType: String?
        let size: Int?
    }

    struct SendFileResult {
        let ok: Bool
        let error: String
    }

    private let token: String
    private let tool: FeedTool
    private let instanceLabel: String
    private let ioTagPrefix: String
    private let home: String                  // 新用户的默认工作目录
    private let allowedChatIDs: Set<String>
    /// 桌宠联动回调:phase ∈ "start"(收到消息开干) / "done"(干完);summary 给横幅。主线程里调。
    private let onActivity: (FeedTool, String, String?) -> Void

    /// 按远程发送者索引的会话态。私聊时发送者 id 通常等于 chat id;群里按发送者拆开,避免多人共享上下文。
    private var contexts: [String: ChatContext] = [:]
    /// 按发送者记最近一次文件任务,让后续纯文字可以继续二次修改上一个文件。
    private var recentFileTasks: [String: RemoteFileTask] = [:]
    private var offset = 0
    private var running = false
    private let urlSession: URLSession
    private static let messageTimeout: TimeInterval = 25
    private static let fileUploadTimeout: TimeInterval = 300
    private static let rawDownloadTimeout: TimeInterval = 75

    init(token: String, tool: FeedTool, instanceLabel: String, ioTagPrefix: String, home: String, allowedChatIDs: Set<String>,
         onActivity: @escaping (FeedTool, String, String?) -> Void) {
        self.token = token
        self.tool = tool
        self.instanceLabel = instanceLabel
        self.ioTagPrefix = ioTagPrefix
        self.home = home
        self.allowedChatIDs = allowedChatIDs
        self.onActivity = onActivity
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 70   // long polling timeout=50,留余量
        cfg.timeoutIntervalForResource = 600
        self.urlSession = URLSession(configuration: cfg)
    }

    /// 取该远程用户的会话态,没有就按默认目录新建。仅轮询线程调用,无需加锁。
    private func context(for remoteUserID: String) -> ChatContext {
        if let ctx = contexts[remoteUserID] { return ctx }
        let tag = tool == .codex ? "cx" : "cc"
        let ctx = ChatContext(tool: tool, cwd: home, label: "agentpet.remote.\(tag).\(ioTagPrefix).\(remoteUserID)")
        contexts[remoteUserID] = ctx
        PetView.log("Telegram[\(instanceLabel)] 新建会话 user \(remoteUserID),默认目录 \(home)")
        return ctx
    }

    func start() {
        guard !running else { return }
        running = true
        Thread.detachNewThread { [weak self] in self?.loop() }
        PetView.log("Telegram[\(instanceLabel)] 轮询启动,默认目录 \(home)")
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
            PetView.log("Telegram[\(instanceLabel)] getUpdates 非 ok: \(obj["description"] as? String ?? "?")")
            return nil
        }
        return obj["result"] as? [[String: Any]] ?? []
    }

    /// 处理一条 update:白名单校验 → 取该 chat 的会话态 → 指令(/cd /pwd /new /help)、文件任务或普通消息(喂 agent)。
    private func handle(_ update: [String: Any]) {
        guard let message = update["message"] as? [String: Any],
              let chat = message["chat"] as? [String: Any] else { return }
        let text = TelegramBot.messageText(from: message)
        let attachments = TelegramBot.fileAttachments(from: message)
        guard !text.isEmpty || !attachments.isEmpty else { return }
        let chatID = String(describing: chat["id"] ?? "")
        // 发起人可读名:优先 @username,退而 first_name + last_name,再退 chat id。供任务监控展示"具体谁发起的"。
        let senderName = TelegramBot.senderDisplayName(from: message["from"] as? [String: Any], chatID: chatID)
        let remoteUserID = TelegramBot.senderID(from: message["from"] as? [String: Any], fallback: chatID)

        // 白名单:非空时只认名单内 chat;空名单放行但记日志提醒主公尽快设白名单。
        if !allowedChatIDs.isEmpty, !allowedChatIDs.contains(chatID) {
            PetView.log("Telegram[\(instanceLabel)] 拒收 chat \(chatID)(不在白名单)")
            sendMessage(chatID: chatID, text: "你不在白名单里,无法下发指令。")
            return
        }
        if allowedChatIDs.isEmpty {
            PetView.log("Telegram[\(instanceLabel)] 警告:未设白名单,chat \(chatID) 已放行")
        }

        let ctx = context(for: remoteUserID)
        if !attachments.isEmpty {
            handleFileMessage(attachments: attachments, text: text, ctx: ctx, chatID: chatID,
                              remoteUserID: remoteUserID, senderName: senderName)
            return
        }

        if shouldContinueRecentFileTask(text), let fileTask = recentFileTask(for: remoteUserID) {
            handleFollowUpFileTask(text: text, fileTask: fileTask, ctx: ctx, chatID: chatID,
                                   remoteUserID: remoteUserID, senderName: senderName)
            return
        }

        switch RemoteBotSetup.handle(platform: "telegram", remoteUserID: remoteUserID,
                                     botID: ioTagPrefix, toolLabel: tool.label,
                                     incoming: text) {
        case .reply(let reply, let resetSession):
            if resetSession { ctx.setSessionID(nil) }
            sendMessage(chatID: chatID, text: reply)
            return
        case .proceed(let personalizedPrompt):
            if text.hasPrefix("/") { handleCommand(text, ctx: ctx, chatID: chatID); return }
            guard ctx.tryBegin() else {
                sendMessage(chatID: chatID, text: "上一条还在跑,等它答完再发哈。")
                return
            }
            runAgent(prompt: personalizedPrompt, originalPrompt: text, ctx: ctx, chatID: chatID,
                     remoteUserID: remoteUserID, senderName: senderName)
        }
    }

    /// 判断纯文字是否明显在继续修改上一份文件,避免普通闲聊误绑到文件任务。
    private func shouldContinueRecentFileTask(_ text: String) -> Bool {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !value.hasPrefix("/") else { return false }
        let needles = ["继续", "再", "二次", "修改", "改", "调整", "换", "加", "去掉", "删除", "放大", "缩小",
                       "变成", "改成", "重新", "上一张", "上一个", "上一份", "刚才", "刚刚", "这个", "那个",
                       "图片", "照片", "图", "文件", "文档", "表格", "pdf", "word", "excel", "csv", "json",
                       "音频", "视频", "压缩包", "附件", "处理", "完成", "完了吗", "好了没", "好了吗", "结束",
                       "continue", "again", "modify", "edit", "change", "previous", "last file", "last document",
                       "last image", "file", "document", "attachment", "done", "finished", "complete"]
        return needles.contains { value.contains($0) }
    }

    private func recentFileTask(for remoteUserID: String) -> RemoteFileTask? {
        if let task = recentFileTasks[remoteUserID] { return task }
        guard let task = RemoteFileTask.latestExisting(platform: "telegram", botID: ioTagPrefix, remoteUserID: remoteUserID) else {
            return nil
        }
        recentFileTasks[remoteUserID] = task
        PetView.log("Telegram[\(instanceLabel)] user \(remoteUserID) 从磁盘恢复最近文件任务 \(task.taskID)")
        return task
    }

    private func handleFollowUpFileTask(text: String, fileTask: RemoteFileTask, ctx: ChatContext, chatID: String,
                                        remoteUserID: String, senderName: String) {
        let prompt = fileTask.followUpPrompt(userRequest: text)
        switch RemoteBotSetup.handle(platform: "telegram", remoteUserID: remoteUserID,
                                     botID: ioTagPrefix, toolLabel: tool.label,
                                     incoming: prompt) {
        case .reply(let reply, let resetSession):
            if resetSession { ctx.setSessionID(nil) }
            sendMessage(chatID: chatID, text: reply)
        case .proceed(let personalizedPrompt):
            guard ctx.tryBegin() else {
                sendMessage(chatID: chatID, text: "上一条还在处理,等它答完后再继续。")
                return
            }
            runAgent(prompt: personalizedPrompt, originalPrompt: text, ctx: ctx, chatID: chatID,
                     remoteUserID: remoteUserID, senderName: senderName, fileTask: fileTask)
        }
    }

    /// Telegram 文本优先取 text,文件说明取 caption。
    static func messageText(from message: [String: Any]) -> String {
        let raw = (message["text"] as? String) ?? (message["caption"] as? String) ?? ""
        return raw.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 从 Telegram message 中提取所有带 file_id 的常见文件类型。photo 只取最大尺寸,避免同一照片重复下载。
    static func fileAttachments(from message: [String: Any]) -> [FileAttachment] {
        var result: [FileAttachment] = []
        func item(_ kind: String, _ raw: [String: Any], defaultName: String? = nil, mimeType: String? = nil) -> FileAttachment? {
            guard let fileID = raw["file_id"] as? String, !fileID.isEmpty else { return nil }
            return FileAttachment(kind: kind,
                                  fileID: fileID,
                                  fileUniqueID: raw["file_unique_id"] as? String,
                                  fileName: (raw["file_name"] as? String) ?? defaultName,
                                  mimeType: (raw["mime_type"] as? String) ?? mimeType,
                                  size: raw["file_size"] as? Int)
        }
        if let raw = message["document"] as? [String: Any], let f = item("document", raw) { result.append(f) }
        if let photos = message["photo"] as? [[String: Any]], let raw = photos.max(by: {
            (($0["file_size"] as? Int) ?? (($0["width"] as? Int) ?? 0) * (($0["height"] as? Int) ?? 0))
            < (($1["file_size"] as? Int) ?? (($1["width"] as? Int) ?? 0) * (($1["height"] as? Int) ?? 0))
        }), let f = item("photo", raw, defaultName: "photo.jpg", mimeType: "image/jpeg") { result.append(f) }
        if let raw = message["video"] as? [String: Any], let f = item("video", raw, defaultName: "video.mp4", mimeType: "video/mp4") { result.append(f) }
        if let raw = message["audio"] as? [String: Any], let f = item("audio", raw, defaultName: "audio.mp3") { result.append(f) }
        if let raw = message["voice"] as? [String: Any], let f = item("voice", raw, defaultName: "voice.ogg", mimeType: "audio/ogg") { result.append(f) }
        if let raw = message["animation"] as? [String: Any], let f = item("animation", raw, defaultName: "animation.mp4") { result.append(f) }
        if let raw = message["sticker"] as? [String: Any] {
            let ext = (raw["is_video"] as? Bool) == true ? "webm" : ((raw["is_animated"] as? Bool) == true ? "tgs" : "webp")
            if let f = item("sticker", raw, defaultName: "sticker.\(ext)") { result.append(f) }
        }
        if let raw = message["video_note"] as? [String: Any], let f = item("video_note", raw, defaultName: "video-note.mp4", mimeType: "video/mp4") { result.append(f) }
        return result
    }

    /// 文件消息先落隔离目录,再把任务目录交给 agent。下载失败不会进入执行链路。
    private func handleFileMessage(attachments: [FileAttachment], text: String, ctx: ChatContext, chatID: String,
                                   remoteUserID: String, senderName: String) {
        let task: RemoteFileTask
        do {
            task = try RemoteFileTask.create(platform: "telegram", botID: ioTagPrefix, remoteUserID: remoteUserID)
        } catch {
            PetView.log("Telegram[\(instanceLabel)] 创建文件任务目录失败:\(error.localizedDescription)")
            sendMessage(chatID: chatID, text: "文件接收失败:无法创建任务目录。")
            return
        }

        // 新建任务后机会式回收历史文件(带 6 小时节流,绝大多数调用直接返回),防 ~/AgentPetRemoteFiles 永久堆积。
        RemoteFileTask.maybeCleanup()

        var saved: [RemoteFileTask.InputFile] = []
        var failures: [String] = []
        for attachment in attachments {
            do {
                let file = try downloadAttachment(attachment, into: task)
                saved.append(file)
            } catch {
                failures.append("\(attachment.kind):\(error.localizedDescription)")
            }
        }
        do {
            try task.writeMeta(chatID: chatID, senderName: senderName, toolLabel: tool.label,
                               requestText: text, files: saved)
        } catch {
            failures.append("meta:\(error.localizedDescription)")
        }

        guard !saved.isEmpty else {
            PetView.log("Telegram[\(instanceLabel)] 文件下载失败:\(failures.joined(separator: "; "))")
            sendMessage(chatID: chatID, text: "文件接收失败:下载文件没有成功。")
            return
        }

        let prompt = task.prompt(userRequest: text, files: saved)
        switch RemoteBotSetup.handle(platform: "telegram", remoteUserID: remoteUserID,
                                     botID: ioTagPrefix, toolLabel: tool.label,
                                     incoming: prompt) {
        case .reply(let reply, let resetSession):
            if resetSession { ctx.setSessionID(nil) }
            sendMessage(chatID: chatID, text: """
            文件已收到。当前 Bot 需要先完成设置:
            \(reply)
            """)
            return
        case .proceed(let personalizedPrompt):
            guard ctx.tryBegin() else {
                sendMessage(chatID: chatID, text: "文件已收到。上一条还在处理,等它答完后再继续。")
                return
            }
            if !failures.isEmpty {
                PetView.log("Telegram[\(instanceLabel)] 部分文件处理异常:\(failures.joined(separator: "; "))")
                sendMessage(chatID: chatID, text: "部分文件接收失败,已继续处理成功收到的文件。")
            }
            recentFileTasks[remoteUserID] = task
            PetView.log("Telegram[\(instanceLabel)] user \(remoteUserID) 最近文件任务更新为 \(task.taskID)")
            let names = saved.map(\.storedName).joined(separator: ", ")
            runAgent(prompt: personalizedPrompt, originalPrompt: text.isEmpty ? "Telegram 文件任务:\(names)" : text,
                     ctx: ctx, chatID: chatID, remoteUserID: remoteUserID, senderName: senderName, fileTask: task)
        }
    }

    /// Telegram 的真实发送者 id。群聊里 chat id 是群,必须用 from.id 才能按人隔离。
    static func senderID(from raw: [String: Any]?, fallback: String) -> String {
        guard let from = raw, let id = from["id"] else { return fallback }
        return String(describing: id)
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
            我是 \(tool.label) 远程遥控。直接发消息或文件我就替你干活;支持:
            /cd <路径>  切换工作目录(并开新会话)
            /pwd        看当前目录
            /new        开新会话(清上下文)
            /setup      重新设置当前 Bot
            /profile    查看当前 Bot 设置
            /reset      清空当前 Bot 设置并重新引导
            /help       这条帮助
            发文件时可在 caption 写处理要求;结果文件请让 agent 放到 outbox,会自动回传。
            当前目录:\(ctx.cwd)
            """)
        default:
            sendMessage(chatID: chatID, text: "不认得指令 \(cmd),发 /help 看用法。")
        }
    }

    /// 把消息当 prompt 喂给 agent:派到该 chat 的串行队列后台跑,轮询线程立刻返回继续收别人的消息。
    /// 流程:桌宠开跑 → 先占一条进度消息 → 边跑边把 cc/cx 的步骤原地编辑进这条消息 → 写回会话 id、解忙 → 收尾进度 + 另发最终正文 → 桌宠收工。
    /// 调用前 handle 已 tryBegin() 占用。进度回调在 AgentRunner 的读取线程里触发,经 ProgressPanel 节流后才真正发编辑请求,避免触发 Telegram 限流。
    private func runAgent(prompt: String, originalPrompt: String, ctx: ChatContext, chatID: String,
                          remoteUserID: String, senderName: String, fileTask: RemoteFileTask? = nil) {
        let tool = self.tool
        ctx.queue.async { [weak self] in
            guard let self = self else { return }
            DispatchQueue.main.async { self.onActivity(tool, "start", nil) }
            PetView.log("Telegram[\(self.instanceLabel)] user \(remoteUserID) 收到 \(originalPrompt.count) 字,开跑")
            let startedAt = Date()   // 墙钟计时起点:供任务监控算"运行了多长时间"

            // 先占一条进度消息,随后原地编辑刷新;拿不到 message_id 则退化为只在跑完发结果。
            let panelID = self.sendMessage(chatID: chatID, text: fileTask == nil ? "🤖 收到,开跑…" : "🤖 文件已收到,开始处理…")
            let panel = fileTask == nil
                ? ProgressPanel(title: "\(tool.label) 远程进度")
                : ProgressPanel(title: "文件处理中", maxLines: 3)

            let snap = ctx.snapshot()
            let runCwd = fileTask?.root.path ?? snap.cwd
            let runSessionID = fileTask == nil ? snap.sessionID : nil
            let reply = AgentRunner.run(tool: tool, prompt: prompt, sessionID: runSessionID,
                                        cwd: runCwd, ioTag: "\(self.ioTagPrefix)-\(chatID)") { [weak self] line in
                guard let self = self, let panelID = panelID else { return }
                guard let visibleLine = self.userFacingProgress(line, fileTask: fileTask) else { return }
                panel.append(visibleLine)
                if panel.shouldFlush() { self.editMessageText(chatID: chatID, messageID: panelID, text: panel.render()) }
            }
            if fileTask == nil { ctx.setSessionID(reply.sessionID) }
            ctx.end()

            // 任务监控:落盘本轮"问题→答案"连同发起人、耗时、花费(开关关闭时 record 内部直接跳过)。
            DispatchQueue.main.async {
                TaskMonitor.record(source: "telegram", tool: tool, initiatorID: remoteUserID, initiatorName: senderName,
                                   cwd: runCwd, question: originalPrompt, answer: reply.text,
                                   startedAt: startedAt, endedAt: Date(), status: reply.status,
                                   sessionID: reply.sessionID, metrics: reply.metrics)
            }

            // 进度面板收尾(强制刷最后一版),最终正文另发(可能多段、长文)。
            if let panelID = panelID {
                self.editMessageText(chatID: chatID, messageID: panelID, text: panel.renderDone())
            }
            self.sendMessage(chatID: chatID, text: self.userFacingReply(reply.text, fileTask: fileTask))
            if let fileTask = fileTask {
                self.sendOutboxFiles(chatID: chatID, fileTask: fileTask)
            }
            let summary = reply.text.split(whereSeparator: \.isNewline).first.map(String.init) ?? reply.text
            DispatchQueue.main.async { self.onActivity(tool, "done", String(summary.prefix(40))) }
        }
    }

    // MARK: 回话
    /// 下载 Telegram 文件到当前任务 inbox。文件名优先用消息自带名称,再退到 getFile 返回路径的文件名。
    private func downloadAttachment(_ attachment: FileAttachment, into task: RemoteFileTask) throws -> RemoteFileTask.InputFile {
        var comps = URLComponents(string: "https://api.telegram.org/bot\(token)/getFile")!
        comps.queryItems = [URLQueryItem(name: "file_id", value: attachment.fileID)]
        guard let obj = syncGET(comps.url),
              (obj["ok"] as? Bool) == true,
              let result = obj["result"] as? [String: Any],
              let filePath = result["file_path"] as? String,
              !filePath.isEmpty else {
            throw NSError(domain: "AgentPetTelegramFile", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "getFile 没有返回可下载路径"])
        }
        let remoteName = attachment.fileName ?? URL(fileURLWithPath: filePath).lastPathComponent
        let dest = task.reserveInboxURL(fileName: remoteName)
        let encodedPath = filePath.split(separator: "/").map { part in
            String(part).addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? String(part)
        }.joined(separator: "/")
        guard let url = URL(string: "https://api.telegram.org/file/bot\(token)/\(encodedPath)"),
              let data = syncRawData(URLRequest(url: url)) else {
            throw NSError(domain: "AgentPetTelegramFile", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "下载文件失败"])
        }
        try data.write(to: dest, options: .atomic)
        return RemoteFileTask.InputFile(sourceKind: attachment.kind,
                                        fileID: attachment.fileID,
                                        originalName: remoteName,
                                        storedName: dest.lastPathComponent,
                                        path: dest.path,
                                        size: attachment.size ?? data.count,
                                        mimeType: attachment.mimeType)
    }

    /// 只上传当前任务 outbox 的普通文件,不接受任意路径。
    private func sendOutboxFiles(chatID: String, fileTask: RemoteFileTask) {
        let files = fileTask.outboxFiles()
        guard !files.isEmpty else { return }
        var sent = 0
        for file in files {
            let result = sendDocument(chatID: chatID, fileURL: file, caption: file.lastPathComponent)
            if result.ok {
                sent += 1
            } else {
                let detail = result.error.isEmpty ? "未知错误" : result.error
                PetView.log("Telegram[\(instanceLabel)] sendDocument 失败 \(file.path): \(detail)")
                sendMessage(chatID: chatID, text: "回传失败:\(file.lastPathComponent)\n原因:\(detail)")
            }
        }
        if sent > 0 {
            sendMessage(chatID: chatID, text: sent == files.count ? "结果文件已回传。" : "部分结果文件已回传。")
        }
        PetView.log("Telegram[\(instanceLabel)] 文件任务 \(fileTask.taskID) outbox 回传 \(sent)/\(files.count)")
    }

    /// 文件任务回复给用户时去掉内部路径和长篇过程,内部日志仍保留完整信息。
    private func userFacingReply(_ text: String, fileTask: RemoteFileTask?) -> String {
        guard fileTask != nil else { return text }
        let blocked = ["AgentPetRemoteFiles", "/Users/", "/var/", "inbox/", "work/", "outbox/", "meta.json",
                       "本次 Telegram 文件任务目录", "收到的原始文件", "处理中间文件", "需要回传",
                       "```bash", "```sh", "```zsh", "```shell", "$ ", "/bin/", "/usr/bin/", "/opt/homebrew/",
                       "命令:", "命令：", "执行命令", "运行命令", "command:"]
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
            .filter { line in !blocked.contains { line.contains($0) } }
        let compact = lines.joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let fallback = "处理完成。结果文件如已生成会自动回传。"
        let value = compact.isEmpty ? fallback : compact
        return value.count > 1200 ? String(value.prefix(1200)) + "\n…（已省略部分过程）" : value
    }

    /// Telegram 用户侧进度不暴露命令、路径、工具参数。完整细节只保留在本机日志和任务目录里。
    private func userFacingProgress(_ line: String, fileTask: RemoteFileTask?) -> String? {
        if fileTask != nil {
            if line.contains("已就绪") || line.contains("开跑") { return "🟢 已开始处理文件" }
            if line.contains("改动文件") { return "📝 正在生成结果" }
            if line.hasPrefix("💬") { return nil }
            return "🔄 正在处理文件…"
        }
        let sensitive = ["$ ", "/Users/", "/var/", "/bin/", "/usr/bin/", "/opt/homebrew/",
                         "AgentPetRemoteFiles", "inbox/", "work/", "outbox/", "meta.json"]
        if line.hasPrefix("🔧") || sensitive.contains(where: { line.contains($0) }) {
            return "🔧 正在处理"
        }
        return line
    }

    /// 发消息回 Telegram;>4000 字按段切(上限 4096),逐段发。返回最后一段的 message_id(占位进度消息靠它后续原地编辑)。
    @discardableResult
    private func sendMessage(chatID: String, text: String) -> Int? {
        var lastMessageID: Int?
        for chunk in TelegramBot.chunks(text, limit: 4000) {
            var req = URLRequest(url: URL(string: "https://api.telegram.org/bot\(token)/sendMessage")!)
            req.httpMethod = "POST"
            req.timeoutInterval = Self.messageTimeout
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            let body: [String: Any] = ["chat_id": chatID, "text": chunk]
            req.httpBody = try? JSONSerialization.data(withJSONObject: body)
            if let obj = syncData(req), let result = obj["result"] as? [String: Any],
               let mid = result["message_id"] as? Int { lastMessageID = mid }
        }
        return lastMessageID
    }

    /// 用 multipart/form-data 回传单个普通文件。
    func sendDocument(chatID: String, fileURL: URL, caption: String?) -> SendFileResult {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: fileURL.path, isDirectory: &isDir), !isDir.boolValue,
              let data = try? Data(contentsOf: fileURL) else {
            return SendFileResult(ok: false, error: "本地文件不存在或不可读")
        }
        let boundary = "AgentPetBoundary-\(UUID().uuidString)"
        var body = Data()
        func append(_ text: String) { body.append(Data(text.utf8)) }
        func field(_ name: String, _ value: String) {
            append("--\(boundary)\r\n")
            append("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n")
            append(value)
            append("\r\n")
        }
        field("chat_id", chatID)
        if let caption = caption, !caption.isEmpty { field("caption", String(caption.prefix(1000))) }
        let fileName = RemoteFileTask.sanitizeFileName(fileURL.lastPathComponent, fallback: "result")
        let headerFileName = TelegramBot.asciiMultipartFileName(fileName)
        append("--\(boundary)\r\n")
        append("Content-Disposition: form-data; name=\"document\"; filename=\"\(headerFileName)\"\r\n")
        append("Content-Type: \(TelegramBot.mimeType(for: fileURL))\r\n\r\n")
        body.append(data)
        append("\r\n--\(boundary)--\r\n")

        var req = URLRequest(url: URL(string: "https://api.telegram.org/bot\(token)/sendDocument")!)
        req.httpMethod = "POST"
        req.timeoutInterval = Self.fileUploadTimeout
        req.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        req.httpBody = body
        PetView.log("Telegram[\(instanceLabel)] sendDocument 开始 \(fileURL.lastPathComponent),\(data.count) 字节")
        let result = syncTelegramAPI(req)
        guard let obj = result.object else {
            return SendFileResult(ok: false, error: result.error.isEmpty ? "Telegram 没有返回可解析 JSON" : result.error)
        }
        if (obj["ok"] as? Bool) == true { return SendFileResult(ok: true, error: "") }
        let description = obj["description"] as? String ?? result.error
        return SendFileResult(ok: false, error: description.isEmpty ? "Telegram 返回 ok=false" : description)
    }

    /// 原地编辑既有消息(进度面板刷新用)。Telegram 对"内容未变"会回 400,无害,忽略。
    private func editMessageText(chatID: String, messageID: Int, text: String) {
        var req = URLRequest(url: URL(string: "https://api.telegram.org/bot\(token)/editMessageText")!)
        req.httpMethod = "POST"
        req.timeoutInterval = Self.messageTimeout
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
        var req = URLRequest(url: url)
        req.timeoutInterval = Self.rawDownloadTimeout
        return syncData(req)
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
        if sem.wait(timeout: .now() + requestTimeout(request, fallback: Self.rawDownloadTimeout)) == .timedOut {
            task.cancel()
            PetView.log("Telegram[\(instanceLabel)] HTTP 请求超时 \(request.url?.lastPathComponent ?? "?")")
            return nil
        }
        return result
    }

    private func syncTelegramAPI(_ request: URLRequest) -> (object: [String: Any]?, error: String) {
        let sem = DispatchSemaphore(value: 0)
        var object: [String: Any]?
        var message = ""
        let task = urlSession.dataTask(with: request) { data, response, error in
            defer { sem.signal() }
            if let error = error {
                message = error.localizedDescription
                return
            }
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard let data = data, !data.isEmpty else {
                message = "HTTP \(status),响应体为空"
                return
            }
            if let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                object = obj
                if (obj["ok"] as? Bool) != true {
                    let desc = obj["description"] as? String ?? String(data: data, encoding: .utf8) ?? ""
                    message = "HTTP \(status),\(desc)"
                }
                return
            }
            let raw = String(data: data.prefix(500), encoding: .utf8) ?? "\(data.count) 字节非 UTF-8 响应"
            message = "HTTP \(status),响应不是 JSON:\(raw)"
        }
        task.resume()
        if sem.wait(timeout: .now() + requestTimeout(request, fallback: Self.fileUploadTimeout)) == .timedOut {
            task.cancel()
            let seconds = Int(requestTimeout(request, fallback: Self.fileUploadTimeout))
            return (nil, "请求超时(\(seconds)秒),请检查 Telegram 网络或代理")
        }
        return (object, message)
    }

    private func syncRawData(_ request: URLRequest) -> Data? {
        let sem = DispatchSemaphore(value: 0)
        var result: Data?
        let task = urlSession.dataTask(with: request) { data, response, error in
            defer { sem.signal() }
            guard error == nil,
                  let http = response as? HTTPURLResponse,
                  (200..<300).contains(http.statusCode),
                  let data = data else { return }
            result = data
        }
        task.resume()
        if sem.wait(timeout: .now() + requestTimeout(request, fallback: Self.rawDownloadTimeout)) == .timedOut {
            task.cancel()
            PetView.log("Telegram[\(instanceLabel)] 原始文件下载超时 \(request.url?.lastPathComponent ?? "?")")
            return nil
        }
        return result
    }

    private func requestTimeout(_ request: URLRequest, fallback: TimeInterval) -> TimeInterval {
        let timeout = request.timeoutInterval > 0 ? request.timeoutInterval : fallback
        return timeout + 5
    }

    static func asciiMultipartFileName(_ raw: String) -> String {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-")
        let cleaned = raw.unicodeScalars.map { allowed.contains($0) ? Character($0) : "_" }
        let value = String(cleaned).trimmingCharacters(in: CharacterSet(charactersIn: "._-"))
        return value.isEmpty ? "result.bin" : String(value.prefix(120))
    }

    static func mimeType(for url: URL) -> String {
        switch url.pathExtension.lowercased() {
        case "gif": return "image/gif"
        case "jpg", "jpeg": return "image/jpeg"
        case "png": return "image/png"
        case "webp": return "image/webp"
        case "pdf": return "application/pdf"
        case "txt", "md", "log": return "text/plain"
        case "csv": return "text/csv"
        case "json": return "application/json"
        case "zip": return "application/zip"
        case "mp4": return "video/mp4"
        case "mp3": return "audio/mpeg"
        case "ogg": return "audio/ogg"
        default: return "application/octet-stream"
        }
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

        // Telegram:cc/cx 各自可填多枚 token;每枚 token 启一个独立 bot,适合每个人一枚专属 bot。
        let allow = Settings.telegramAllowedChatIDSet
        for (idx, token) in Settings.telegramClaudeTokens.enumerated() {
            bots.append(makeBot(token: token, tool: .claude, home: home, allow: allow, index: idx + 1))
        }
        for (idx, token) in Settings.telegramCodexTokens.enumerated() {
            bots.append(makeBot(token: token, tool: .codex, home: home, allow: allow, index: idx + 1))
        }
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
        RemoteFeatureAnnouncement.pushIfNeeded()
    }

    private func makeBot(token: String, tool: FeedTool, home: String, allow: Set<String>, index: Int) -> TelegramBot {
        let tag = tool == .codex ? "cx" : "cc"
        let label = "\(tool.label)#\(index)"
        return TelegramBot(token: token, tool: tool, instanceLabel: label, ioTagPrefix: "\(tag)-bot\(index)",
                           home: home, allowedChatIDs: allow) { [weak self] tool, phase, summary in
            self?.onActivity?(tool, phase, summary)
        }
    }

    private func makeFeishuBot(appID: String, appSecret: String, tool: FeedTool, home: String, allow: Set<String>) -> FeishuBot {
        return FeishuBot(appID: appID, appSecret: appSecret, tool: tool, home: home, allowedOpenIDs: allow) { [weak self] tool, phase, summary in
            self?.onActivity?(tool, phase, summary)
        }
    }
}

/// 远程功能公告:每台电脑、每个 Telegram bot、每个白名单 chat 对同一公告版本只推送一次。
/// 只向白名单推送;白名单为空时跳过,避免新机器初次配置时误发到未知会话。
enum RemoteFeatureAnnouncement {
    static let version = "remoteBotPersonalizedSetup.v1"

    static let message = """
    ✨ AgentPet 远程 Bot 个性化设置上线啦

    各位主公请注意：
    从现在开始，远程 Bot 不再是一个冷冰冰的打工机器了。
    它可以有名字、有称呼、有脾气，甚至可以稍微有点人设。

    🧭 第一次使用先做个小设置

    首次使用 Bot 时，会先请您完成一次个性化设置。
    设置没完成前，普通问题会先被拦住，Bot 会乖乖提醒您先设置，不会直接开工乱跑。

    您可以选择：

    1️⃣ 一步步设置
    适合慢慢调教。

    会依次问您：

    🏷️ Bot 叫什么名字
    比如：德全、小智、阿福、代码管家

    🙋 Bot 怎么称呼您
    比如：老板、主公、主人、张总、小李

    🎭 Bot 用什么说话风格
    比如：正常、简洁专业、温柔耐心、古风恭敬

    2️⃣ 一句话快速设置
    适合懒得一步步答的主公。

    直接这样说就行：
    “你叫德全，称呼我为主公，说话恭敬一点，但不要太啰嗦。”

    Bot 会自己努力理解。
    理解不全的地方，它会再追问您，不会装懂。

    🔒 每个人都有自己的 Bot 设置

    不用担心串味。
    同一个 Bot，在不同用户那里可以是不同名字、不同称呼、不同风格。
    您的 Bot 是您的，别人的 Bot 是别人的，互不影响。

    🛠️ 常用命令

    /setup
    重新设置当前 Bot

    /profile
    查看当前 Bot 的设置

    /reset
    清空当前设置，然后重新开始

    /help
    查看帮助

    💡 小提示

    如果您之前已经用过这个 Bot，想体验新设置流程，可以直接发送：
    /setup

    或者想从头来过，就发送：
    /reset

    好了，调教开始。
    请给您的 Bot 一个响亮的名字吧。
    """

    struct Target {
        let platform: String
        let toolID: String
        let credentialA: String
        let credentialB: String
        let recipientID: String
    }

    static func pendingTargets() -> [Target] {
        guard Settings.remoteEnabled else { return [] }
        return pendingTelegramTargets() + pendingFeishuTargets()
    }

    static func pendingTelegramTargets() -> [Target] {
        let chats = Settings.telegramAllowedChatIDSet.sorted()
        guard !chats.isEmpty else { return [] }
        let bots: [(String, String)] =
            Settings.telegramClaudeTokens.enumerated().map { ("cc-bot\($0.offset + 1)", $0.element) } +
            Settings.telegramCodexTokens.enumerated().map { ("cx-bot\($0.offset + 1)", $0.element) }
        return bots.flatMap { bot in
            chats.compactMap { chat in
                wasSent(platform: "telegram", toolID: bot.0, recipientID: chat)
                    ? nil
                    : Target(platform: "telegram", toolID: bot.0, credentialA: bot.1, credentialB: "", recipientID: chat)
            }
        }
    }

    static func pendingFeishuTargets() -> [Target] {
        let openIDs = Settings.feishuAllowedOpenIDSet.sorted()
        guard !openIDs.isEmpty else { return [] }
        let bots: [(String, String, String)] = [
            ("claude", Settings.feishuClaudeAppID, Settings.feishuClaudeAppSecret),
            ("codex", Settings.feishuCodexAppID, Settings.feishuCodexAppSecret),
        ].filter { !$0.1.isEmpty && !$0.2.isEmpty }
        return bots.flatMap { bot in
            openIDs.compactMap { openID in
                wasSent(platform: "feishu", toolID: bot.0, recipientID: openID)
                    ? nil
                    : Target(platform: "feishu", toolID: bot.0, credentialA: bot.1, credentialB: bot.2, recipientID: openID)
            }
        }
    }

    static func pushIfNeeded() {
        let targets = pendingTargets()
        guard !targets.isEmpty else {
            if Settings.remoteEnabled, Settings.telegramAllowedChatIDSet.isEmpty {
                PetView.log("远程公告:未配置 Telegram 白名单,跳过自动推送")
            }
            if Settings.remoteEnabled, Settings.feishuAllowedOpenIDSet.isEmpty {
                PetView.log("远程公告:未配置飞书 open_id 白名单,跳过自动推送")
            }
            return
        }
        DispatchQueue.global().async {
            var sent = 0
            for target in targets {
                let ok: Bool
                switch target.platform {
                case "telegram":
                    ok = sendTelegram(token: target.credentialA, chatID: target.recipientID, text: message)
                case "feishu":
                    ok = sendFeishu(appID: target.credentialA, appSecret: target.credentialB, openID: target.recipientID, text: message)
                default:
                    ok = false
                }
                if ok {
                    markSent(platform: target.platform, toolID: target.toolID, recipientID: target.recipientID)
                    sent += 1
                }
            }
            PetView.log("远程公告:\(version) 自动推送完成,成功 \(sent)/\(targets.count) 条")
        }
    }

    private static func key(platform: String, toolID: String, recipientID: String) -> String {
        "remoteAnnouncement.\(version).\(platform).\(toolID).\(recipientID)"
    }

    private static func wasSent(platform: String, toolID: String, recipientID: String) -> Bool {
        UserDefaults.standard.bool(forKey: key(platform: platform, toolID: toolID, recipientID: recipientID))
    }

    private static func markSent(platform: String, toolID: String, recipientID: String) {
        UserDefaults.standard.set(true, forKey: key(platform: platform, toolID: toolID, recipientID: recipientID))
    }

    private static func sendTelegram(token: String, chatID: String, text: String) -> Bool {
        var ok = false
        let sem = DispatchSemaphore(value: 0)
        guard let url = URL(string: "https://api.telegram.org/bot\(token)/sendMessage") else { return false }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: ["chat_id": chatID, "text": text])
        URLSession.shared.dataTask(with: req) { data, _, error in
            defer { sem.signal() }
            guard error == nil,
                  let data = data,
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  (obj["ok"] as? Bool) == true else { return }
            ok = true
        }.resume()
        _ = sem.wait(timeout: .now() + 20)
        return ok
    }

    private static func sendFeishu(appID: String, appSecret: String, openID: String, text: String) -> Bool {
        FeishuAPI(appID: appID, appSecret: appSecret).sendText(receiveID: openID, receiveIDType: "open_id", text: text) != nil
    }
}

/// 远程遥控配置窗:独立小窗,不挤进已爆满的主设置窗。手写 AppKit 绝对布局。
/// 收总开关 + cc/cx 两组 bot token 列表 + chat id 白名单;保存即写 UserDefaults 并 RemoteControl.reload。
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
        note("每个人可各建专属 bot;多枚 token 用逗号/空格分隔。发消息后用 getUpdates 看 chat id。", y: 634)
        label("cc bot tokens(可多枚)", y: 608); field(claudeTokenField, y: 584)
        label("Codex(cx)bot tokens(可多枚)", y: 556); field(codexTokenField, y: 532)
        label("允许的 chat id(逗号/空格分隔,留空=不限,但不安全)", y: 504); field(allowedField, y: 480)

        // ── 飞书 ──
        section("飞书(Feishu,仅国内版 open.feishu.cn)", y: 444)
        note("各建企业自建应用:开机器人 + im:message 权限,事件订阅选「长连接」订 im.message.receive_v1。", y: 422)
        label("cc App ID", y: 398); field(feishuClaudeAppIDField, y: 374)
        label("cc App Secret", y: 346); field(feishuClaudeAppSecretField, y: 322)
        label("Codex(cx)App ID", y: 294); field(feishuCodexAppIDField, y: 270)
        label("Codex(cx)App Secret", y: 242); field(feishuCodexAppSecretField, y: 218)
        label("允许的 open_id(逗号/空格分隔,留空=不限,但不安全)", y: 190); field(feishuAllowedField, y: 166)

        // 底部提示 + 按钮
        let tip = NSTextField(labelWithString: "改完点「保存并应用」立即生效;token 可多枚,留空则对应 bot 不启动。\ntoken / app secret 只存本机,不入仓库。")
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
