// MARK: - 任务监控:把远程遥控(Telegram / 飞书)每一轮"问题→答案"连同发起人、耗时、花费落盘,
// 并内嵌一个零依赖的本地 HTTP 服务对外暴露这些数据,供独立前端项目 agent-pet-monitor 做仪表盘。
//
// 本模块刻意独立成文件(不并进 main.swift):监控链路自洽,记录与服务都不碰桌宠外观。
// 仍由 build.sh 与 main.swift / RemoteControl.swift / FeishuRemote.swift 一起 `swiftc -swift-version 5` 编进同一二进制。
//
// 设计取舍:
// - 落盘用 JSONL(一行一条记录),追加成本低、易增量读、坏一行不毁全文件;路径在 Application Support 下,卸载前端也不丢历史。
// - HTTP 服务用系统自带 Network 框架(NWListener),零三方依赖,契合本项目"单二进制、不引包"的约束。
// - 前端资源(Node 项目 build 出的 dist)由本服务托管;dist 缺失时回退到内置单文件页面,保证开关一开即用,不强依赖 Node 构建。

import AppKit
import Network
import Security

/// 一轮调用的计量:墙钟时长之外,Claude 的 result 事件带 CLI 自报的时长 / 花费 / token;
/// Codex 的 turn.completed 事件带 token,但本地 JSONL 不含可直接落盘的美元花费。
struct AgentMetrics {
    var cliDurationMs: Int?     // claude result.duration_ms
    var costUSD: Double?        // claude result.total_cost_usd
    var inputTokens: Int?       // cc/cx 输入 token
    var outputTokens: Int?      // cc/cx 输出 token(含推理输出)
    var numTurns: Int?          // claude result.num_turns
}

/// 一条任务记录:监控页面的最小展示单元。字段保持扁平,便于前端直接消费,也便于 JSONL 逐行解析。
struct TaskRecord: Codable {
    let id: String              // 全局唯一(毫秒时间戳 + 自增序号)
    let source: String          // telegram | feishu
    let tool: String            // claude | codex
    let initiatorID: String     // 发起人标识:Telegram chat id / 飞书 open_id
    let initiatorName: String   // 发起人可读名:Telegram 用户名,飞书暂用 open_id
    let cwd: String             // 任务工作目录
    let question: String        // 发起的问题(prompt 原文)
    let answer: String          // 最终答案(回传聊天的正文)
    let startedAt: Double       // 开跑时刻(epoch 秒,带小数)
    let endedAt: Double         // 答完时刻(epoch 秒,带小数)
    let durationMs: Int         // 墙钟时长(从收到到答完)
    let cliDurationMs: Int?     // CLI 自报时长(仅 claude)
    let costUSD: Double?        // 本轮花费美元(仅 claude)
    let inputTokens: Int?       // 输入 token(cc/cx 能拿则填)
    let outputTokens: Int?      // 输出 token(cc/cx 能拿则填)
    let numTurns: Int?          // 内部回合数(仅 claude)
    let status: String          // ok | timeout | error
    let sessionID: String?      // 续接会话 id
}

/// 记录存储:追加 JSONL、整文件读回。所有文件读写串到一条串行队列,避免并发写串行。
enum TaskMonitorStore {
    /// 串行队列:记录来自不同用户的多条后台线程,统一串行写,杜绝交错。
    private static let queue = DispatchQueue(label: "agentpet.monitor.store")
    private static var counter = 0

    /// 数据目录:~/Library/Application Support/com.agent.pet/monitor。卸载前端不影响这里的历史。
    static var dataDirectory: String {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?.path
            ?? (NSHomeDirectory() + "/Library/Application Support")
        return base + "/com.agent.pet/monitor"
    }

    static var logPath: String { dataDirectory + "/tasks.jsonl" }

    /// 生成全局唯一 id:毫秒时间戳拼自增序号,同一毫秒内多条也不撞。
    static func makeID() -> String {
        return queue.sync {
            counter += 1
            let ms = Int(Date().timeIntervalSince1970 * 1000)
            return "\(ms)-\(counter)"
        }
    }

    /// 追加一条记录(一行 JSON)。失败只记日志,绝不影响主流程(监控丢一条远不如卡住答话严重)。
    static func append(_ record: TaskRecord) {
        queue.async {
            do {
                try FileManager.default.createDirectory(atPath: dataDirectory, withIntermediateDirectories: true)
                let encoder = JSONEncoder()
                guard var data = try? encoder.encode(record) else { return }
                data.append(0x0A) // 换行,凑成 JSONL 一行
                if let handle = FileHandle(forWritingAtPath: logPath) {
                    defer { try? handle.close() }
                    try handle.seekToEnd()
                    try handle.write(contentsOf: data)
                } else {
                    try data.write(to: URL(fileURLWithPath: logPath))
                }
            } catch {
                PetView.log("监控:写记录失败 \(error.localizedDescription)")
            }
        }
    }

    /// 读回全部记录(按写入顺序)。坏行跳过,不让一行损坏拖垮整页。可选 limit 只取最新若干条。
    static func readAll(limit: Int? = nil) -> [TaskRecord] {
        return queue.sync {
            guard let text = try? String(contentsOfFile: logPath, encoding: .utf8) else { return [] }
            let decoder = JSONDecoder()
            var records: [TaskRecord] = []
            for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
                guard let data = line.data(using: .utf8),
                      let rec = try? decoder.decode(TaskRecord.self, from: data) else { continue }
                records.append(rec)
            }
            if let limit = limit, records.count > limit {
                return Array(records.suffix(limit))
            }
            return records
        }
    }

    /// 重写任务记录:用于监控管理页按用户删除历史。仍保持 JSONL 格式,坏行已在 readAll 阶段被跳过。
    static func removeRecords(source: String, initiatorID: String) -> Int {
        queue.sync {
            let decoder = JSONDecoder()
            let text = (try? String(contentsOfFile: logPath, encoding: .utf8)) ?? ""
            let all = text.split(separator: "\n", omittingEmptySubsequences: true).compactMap { line -> TaskRecord? in
                guard let data = line.data(using: .utf8) else { return nil }
                return try? decoder.decode(TaskRecord.self, from: data)
            }
            let records = all.filter { !($0.source == source && $0.initiatorID == initiatorID) }
            do {
                try FileManager.default.createDirectory(atPath: dataDirectory, withIntermediateDirectories: true)
                let encoder = JSONEncoder()
                var data = Data()
                for record in records {
                    guard var row = try? encoder.encode(record) else { continue }
                    row.append(0x0A)
                    data.append(row)
                }
                try data.write(to: URL(fileURLWithPath: logPath), options: .atomic)
                return max(0, all.count - records.count)
            } catch {
                PetView.log("监控:删除任务记录失败 \(error.localizedDescription)")
                return 0
            }
        }
    }
}

/// 监控管理认证:管理员密码放 macOS Keychain,登录后签发内存 token。
enum MonitorAdminAuth {
    private static let queue = DispatchQueue(label: "agentpet.monitor.admin.auth")
    private static let service = "com.agent.pet.monitor.admin"
    private static let account = "admin"
    private static let tokenTTL: TimeInterval = 12 * 60 * 60
    private static var sessions: [String: Date] = [:]

    static func isConfigured() -> Bool { storedPassword() != nil }

    static func setPassword(_ password: String) -> Bool {
        guard password.count >= 6, let data = password.data(using: .utf8) else { return false }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        let attrs: [String: Any] = [kSecValueData as String: data]
        let status = SecItemUpdate(query as CFDictionary, attrs as CFDictionary)
        if status == errSecSuccess { return true }
        var add = query
        add[kSecValueData as String] = data
        return SecItemAdd(add as CFDictionary, nil) == errSecSuccess
    }

    static func verify(password: String) -> Bool { storedPassword() == password }

    static func createSession() -> String {
        queue.sync {
            let token = UUID().uuidString + UUID().uuidString
            sessions[token] = Date().addingTimeInterval(tokenTTL)
            return token
        }
    }

    static func validate(token: String?) -> Bool {
        guard let token = token, !token.isEmpty else { return false }
        return queue.sync {
            guard let expires = sessions[token], expires > Date() else {
                sessions.removeValue(forKey: token)
                return false
            }
            sessions[token] = Date().addingTimeInterval(tokenTTL)
            return true
        }
    }

    static func revoke(token: String?) {
        guard let token = token else { return }
        queue.sync { _ = sessions.removeValue(forKey: token) }
    }

    static func runSelfTest() -> Bool {
        let token = createSession()
        return validate(token: token) && !validate(token: "bad-token")
    }

    private static func storedPassword() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }
}

/// 把全部记录聚合成概览统计,供前端直接展示,免得每次都在前端重算。
enum TaskStats {
    /// 返回可被 JSONSerialization 序列化的字典(纯标量 / 数组 / 字典)。
    static func summary(_ records: [TaskRecord]) -> [String: Any] {
        let total = records.count
        let totalCost = records.compactMap { $0.costUSD }.reduce(0, +)
        let totalInput = records.compactMap { $0.inputTokens }.reduce(0, +)
        let totalOutput = records.compactMap { $0.outputTokens }.reduce(0, +)
        let durations = records.map { $0.durationMs }
        let avgDuration = durations.isEmpty ? 0 : durations.reduce(0, +) / durations.count
        let maxDuration = durations.max() ?? 0

        func tally(_ keyPath: (TaskRecord) -> String) -> [[String: Any]] {
            var counts: [String: Int] = [:]
            for r in records { counts[keyPath(r), default: 0] += 1 }
            return counts.sorted { $0.value > $1.value }.map { ["name": $0.key, "count": $0.value] }
        }

        return [
            "total": total,
            "totalCostUSD": totalCost,
            "totalInputTokens": totalInput,
            "totalOutputTokens": totalOutput,
            "avgDurationMs": avgDuration,
            "maxDurationMs": maxDuration,
            "okCount": records.filter { $0.status == "ok" }.count,
            "timeoutCount": records.filter { $0.status == "timeout" }.count,
            "errorCount": records.filter { $0.status == "error" }.count,
            "bySource": tally { $0.source },
            "byTool": tally { $0.tool },
            "byInitiator": tally { $0.initiatorName.isEmpty ? $0.initiatorID : $0.initiatorName },
        ]
    }
}

/// 零依赖本地 HTTP 服务:绑定回环地址,GET 路由分发到 /api 数据接口与前端静态资源。
/// 仅服务本机仪表盘,刻意只听 127.0.0.1;请求都是小 GET,逐连接读到请求头结束即可应答。
final class MonitorServer {
    private let port: UInt16
    private let pluginDir: String?           // 前端 dist 目录;为 nil 或不存在则回退内置页面
    private var listener: NWListener?
    private let queue = DispatchQueue(label: "agentpet.monitor.server")

    init(port: UInt16, pluginDir: String?) {
        self.port = port
        self.pluginDir = pluginDir
    }

    func start() {
        guard listener == nil else { return }
        let params = NWParameters.tcp
        // 只听回环:本地仪表盘无需对外暴露。
        params.requiredLocalEndpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!)
        params.allowLocalEndpointReuse = true
        guard let listener = try? NWListener(using: params) else {
            PetView.log("监控:无法在端口 \(port) 起服务(可能被占用)")
            return
        }
        self.listener = listener
        listener.newConnectionHandler = { [weak self] conn in self?.accept(conn) }
        listener.stateUpdateHandler = { state in
            if case .failed(let err) = state { PetView.log("监控:服务异常 \(err.localizedDescription)") }
        }
        listener.start(queue: queue)
        PetView.log("监控:HTTP 服务已起 http://127.0.0.1:\(port)(前端目录 \(pluginDir ?? "内置回退页"))")
    }

    func stop() {
        listener?.cancel()
        listener = nil
        PetView.log("监控:HTTP 服务已停")
    }

    // MARK: 连接处理
    private func accept(_ conn: NWConnection) {
        conn.start(queue: queue)
        receive(conn, buffer: Data())
    }

    /// 累积接收直到拿到完整请求头和按 Content-Length 声明的 body。
    private func receive(_ conn: NWConnection, buffer: Data) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            guard let self = self else { conn.cancel(); return }
            var buf = buffer
            if let data = data { buf.append(data) }
            if let range = buf.range(of: Data("\r\n\r\n".utf8)) {
                let header = String(data: buf.subdata(in: buf.startIndex..<range.lowerBound), encoding: .utf8) ?? ""
                let bodyStart = range.upperBound
                let expected = self.contentLength(in: header)
                if buf.count >= bodyStart + expected {
                    let body = expected > 0 ? buf.subdata(in: bodyStart..<(bodyStart + expected)) : Data()
                    self.respond(to: header, body: body, on: conn)
                    return
                }
            }
            if isComplete || error != nil || buf.count > 1_048_576 {
                self.respond(to: String(data: buf, encoding: .utf8) ?? "", body: Data(), on: conn)
                return
            }
            self.receive(conn, buffer: buf)
        }
    }

    /// 解析请求行(METHOD PATH HTTP/1.1),路由后写回响应并关闭连接。
    private func respond(to header: String, body: Data, on conn: NWConnection) {
        let firstLine = header.split(separator: "\r\n", maxSplits: 1).first.map(String.init) ?? ""
        let parts = firstLine.split(separator: " ").map(String.init)
        let method = parts.count > 0 ? parts[0] : "GET"
        let rawPath = parts.count > 1 ? parts[1] : "/"
        let path = String(rawPath.split(separator: "?").first ?? "/")
        let token = headerValue("x-agentpet-admin-token", in: header)

        if method == "OPTIONS" {
            send(status: "403 Forbidden", contentType: "text/plain", body: Data("forbidden".utf8), on: conn)
            return
        }

        switch path {
        case "/api/health":
            sendJSON(["ok": true, "records": TaskMonitorStore.readAll().count], on: conn)
        case "/api/admin/status":
            sendJSON(["configured": MonitorAdminAuth.isConfigured(),
                      "authenticated": MonitorAdminAuth.validate(token: token)], on: conn)
        case "/api/admin/setup":
            guard method == "POST" else { sendMethodNotAllowed(on: conn); return }
            guard !MonitorAdminAuth.isConfigured() else {
                sendJSON(["ok": false, "error": "管理员密码已设置"], status: "409 Conflict", on: conn)
                return
            }
            guard let password = jsonString("password", body: body), MonitorAdminAuth.setPassword(password) else {
                sendJSON(["ok": false, "error": "密码至少 6 位"], status: "400 Bad Request", on: conn)
                return
            }
            sendJSON(["ok": true, "token": MonitorAdminAuth.createSession()], on: conn)
        case "/api/admin/login":
            guard method == "POST" else { sendMethodNotAllowed(on: conn); return }
            guard let password = jsonString("password", body: body), MonitorAdminAuth.verify(password: password) else {
                sendJSON(["ok": false, "error": "密码不正确"], status: "401 Unauthorized", on: conn)
                return
            }
            sendJSON(["ok": true, "token": MonitorAdminAuth.createSession()], on: conn)
        case "/api/admin/logout":
            MonitorAdminAuth.revoke(token: token)
            sendJSON(["ok": true], on: conn)
        case "/api/tasks":
            guard requireAdmin(token: token, on: conn) else { return }
            let records = TaskMonitorStore.readAll()
            let body = (try? JSONEncoder().encode(records.reversed().map { $0 })) ?? Data("[]".utf8)
            send(status: "200 OK", contentType: "application/json; charset=utf-8", body: body, on: conn)
        case "/api/stats":
            guard requireAdmin(token: token, on: conn) else { return }
            sendJSON(TaskStats.summary(TaskMonitorStore.readAll()), on: conn)
        case "/api/users":
            guard requireAdmin(token: token, on: conn) else { return }
            sendJSON(["users": RemoteUserAdmin.monitorRows()], on: conn)
        case "/api/users/allowlist":
            guard method == "POST" else { sendMethodNotAllowed(on: conn); return }
            guard requireAdmin(token: token, on: conn) else { return }
            let payload = jsonObject(body)
            let ok = RemoteUserAdmin.addUser(platform: payload["platform"] as? String ?? "",
                                             remoteUserID: payload["remoteUserID"] as? String ?? "",
                                             tool: payload["tool"] as? String ?? "",
                                             telegramBotToken: payload["telegramBotToken"] as? String ?? "",
                                             feishuAppID: payload["feishuAppID"] as? String ?? "",
                                             feishuAppSecret: payload["feishuAppSecret"] as? String ?? "")
            sendJSON(["ok": ok, "users": RemoteUserAdmin.monitorRows()], status: ok ? "200 OK" : "400 Bad Request", on: conn)
        case "/api/users/delete":
            guard method == "POST" else { sendMethodNotAllowed(on: conn); return }
            guard requireAdmin(token: token, on: conn) else { return }
            let payload = jsonObject(body)
            let result = RemoteUserAdmin.deleteUser(platform: payload["platform"] as? String ?? "",
                                                    remoteUserID: payload["remoteUserID"] as? String ?? "",
                                                    removeAllowlist: payload["removeAllowlist"] as? Bool ?? true,
                                                    deleteFiles: payload["deleteFiles"] as? Bool ?? false,
                                                    deleteTasks: payload["deleteTasks"] as? Bool ?? false)
            sendJSON(result, on: conn)
        case "/api/users/clear-session", "/api/users/clear-profile", "/api/users/delete-files", "/api/users/delete-tasks":
            guard method == "POST" else { sendMethodNotAllowed(on: conn); return }
            guard requireAdmin(token: token, on: conn) else { return }
            let payload = jsonObject(body)
            let platform = payload["platform"] as? String ?? ""
            let remoteUserID = payload["remoteUserID"] as? String ?? ""
            let ok: Bool
            switch path {
            case "/api/users/clear-session": ok = RemoteUserAdmin.clearSessions(platform: platform, remoteUserID: remoteUserID)
            case "/api/users/clear-profile": ok = RemoteUserAdmin.clearProfiles(platform: platform, remoteUserID: remoteUserID)
            case "/api/users/delete-files": ok = RemoteUserAdmin.deleteFiles(platform: platform, remoteUserID: remoteUserID) >= 0
            default: ok = TaskMonitorStore.removeRecords(source: platform, initiatorID: remoteUserID) >= 0
            }
            sendJSON(["ok": ok, "users": RemoteUserAdmin.monitorRows()], status: ok ? "200 OK" : "400 Bad Request", on: conn)
        default:
            serveStatic(path: path, on: conn)
        }
    }

    private func requireAdmin(token: String?, on conn: NWConnection) -> Bool {
        guard MonitorAdminAuth.validate(token: token) else {
            sendJSON(["ok": false, "error": MonitorAdminAuth.isConfigured() ? "需要登录" : "需要先设置管理员密码"],
                     status: "401 Unauthorized", on: conn)
            return false
        }
        return true
    }

    private func contentLength(in header: String) -> Int {
        Int(headerValue("content-length", in: header) ?? "") ?? 0
    }

    private func headerValue(_ name: String, in header: String) -> String? {
        for line in header.split(separator: "\r\n").dropFirst() {
            let parts = line.split(separator: ":", maxSplits: 1).map(String.init)
            if parts.count == 2, parts[0].lowercased() == name.lowercased() {
                return parts[1].trimmingCharacters(in: .whitespaces)
            }
        }
        return nil
    }

    private func jsonObject(_ body: Data) -> [String: Any] {
        (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] ?? [:]
    }

    private func jsonString(_ name: String, body: Data) -> String? {
        (jsonObject(body)[name] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 静态资源:优先从前端 dist 取文件;命中目录或未知非 /api 路径回退到 index.html(支持前端路由);dist 缺失则发内置页。
    private func serveStatic(path: String, on conn: NWConnection) {
        guard let dir = pluginDir, FileManager.default.fileExists(atPath: dir + "/index.html") else {
            send(status: "200 OK", contentType: "text/html; charset=utf-8",
                 body: Data(MonitorServer.fallbackPage.utf8), on: conn)
            return
        }
        // 防目录穿越:规整路径,确保仍在 dist 内。
        let clean = path == "/" ? "/index.html" : path
        let candidate = URL(fileURLWithPath: dir + clean).standardized.path
        let root = URL(fileURLWithPath: dir).standardized.path
        var isDir: ObjCBool = false
        if candidate.hasPrefix(root),
           FileManager.default.fileExists(atPath: candidate, isDirectory: &isDir), !isDir.boolValue,
           let data = FileManager.default.contents(atPath: candidate) {
            send(status: "200 OK", contentType: MonitorServer.contentType(for: candidate), body: data, on: conn)
            return
        }
        // SPA 回退:未命中文件就发 index.html,交给前端路由。
        if let data = FileManager.default.contents(atPath: dir + "/index.html") {
            send(status: "200 OK", contentType: "text/html; charset=utf-8", body: data, on: conn)
        } else {
            send(status: "404 Not Found", contentType: "text/plain", body: Data("not found".utf8), on: conn)
        }
    }

    private func sendJSON(_ object: Any, status: String = "200 OK", on conn: NWConnection) {
        let body = (try? JSONSerialization.data(withJSONObject: object)) ?? Data("{}".utf8)
        send(status: status, contentType: "application/json; charset=utf-8", body: body, on: conn)
    }

    private func sendMethodNotAllowed(on conn: NWConnection) {
        sendJSON(["ok": false, "error": "方法不允许"], status: "405 Method Not Allowed", on: conn)
    }

    /// 写回一个完整 HTTP/1.1 响应并关闭连接(短连接,应答即断)。
    private func send(status: String, contentType: String, body: Data, on conn: NWConnection) {
        var head = "HTTP/1.1 \(status)\r\n"
        head += "Content-Type: \(contentType)\r\n"
        head += "Content-Length: \(body.count)\r\n"
        head += "Cache-Control: no-store\r\n"
        head += "Connection: close\r\n\r\n"
        var data = Data(head.utf8)
        data.append(body)
        conn.send(content: data, completion: .contentProcessed { _ in conn.cancel() })
    }

    /// 按扩展名给常见前端资源定 Content-Type。
    static func contentType(for path: String) -> String {
        switch (path as NSString).pathExtension.lowercased() {
        case "html": return "text/html; charset=utf-8"
        case "js", "mjs": return "application/javascript; charset=utf-8"
        case "css": return "text/css; charset=utf-8"
        case "json": return "application/json; charset=utf-8"
        case "svg": return "image/svg+xml"
        case "png": return "image/png"
        case "jpg", "jpeg": return "image/jpeg"
        case "ico": return "image/x-icon"
        case "woff2": return "font/woff2"
        case "woff": return "font/woff"
        default: return "application/octet-stream"
        }
    }

    /// 内置回退页:dist 不存在时也能用的极简仪表盘(纯原生 JS,拉 /api 渲染)。前端项目构建后这页就被 dist 取代。
    static let fallbackPage = """
    <!doctype html><html lang="zh-CN"><head><meta charset="utf-8">
    <meta name="viewport" content="width=device-width,initial-scale=1">
    <title>AgentPet 任务监控</title>
    <style>
    body{font:14px/1.6 -apple-system,system-ui,sans-serif;margin:0;background:#f5f5f7;color:#1d1d1f}
    header{padding:16px 24px;background:#fff;border-bottom:1px solid #e5e5e7;display:flex;align-items:center;gap:16px}
    h1{font-size:18px;margin:0}
    .stats{display:flex;gap:12px;flex-wrap:wrap;padding:16px 24px}
    .card{background:#fff;border:1px solid #e5e5e7;border-radius:10px;padding:12px 16px;min-width:120px}
    .card .n{font-size:22px;font-weight:600}.card .l{color:#86868b;font-size:12px}
    table{width:calc(100% - 48px);margin:0 24px 24px;border-collapse:collapse;background:#fff;border-radius:10px;overflow:hidden}
    th,td{text-align:left;padding:10px 12px;border-bottom:1px solid #f0f0f2;vertical-align:top;font-size:13px}
    th{background:#fafafa;color:#86868b;font-weight:600}
    .q{max-width:280px}.a{max-width:380px;color:#333;white-space:pre-wrap}
    .tag{display:inline-block;padding:1px 8px;border-radius:6px;font-size:12px;background:#eef;color:#3355cc}
    .muted{color:#86868b}.empty{padding:48px;text-align:center;color:#86868b}
    </style></head><body>
    <header><h1>🐾 AgentPet 任务监控</h1><span class="muted" id="updated"></span>
    <span class="muted" style="margin-left:auto">内置回退页 · 构建 agent-pet-monitor 可得完整仪表盘</span></header>
    <div class="stats" id="stats"></div>
    <table id="users"><thead><tr><th>平台</th><th>用户</th><th>Bot</th><th>会话</th><th>设置</th><th>文件任务</th><th>任务记录</th><th>最后活动</th></tr></thead><tbody></tbody></table>
    <table id="tbl"><thead><tr><th>时间</th><th>来源/发起人</th><th>工具</th><th>问题</th><th>答案</th><th>时长</th><th>花费</th></tr></thead><tbody></tbody></table>
    <script>
    const fmtDur=ms=>ms<1000?ms+'ms':(ms/1000).toFixed(1)+'s';
    const fmtTime=s=>new Date(s*1000).toLocaleString('zh-CN');
    const fmtMaybeTime=s=>s>0?fmtTime(s):'—';
    const esc=t=>(t||'').replace(/[&<>]/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;'}[c]));
    async function load(){
      try{
        const [tasks,stats,userPayload]=await Promise.all([fetch('/api/tasks').then(r=>r.json()),fetch('/api/stats').then(r=>r.json()),fetch('/api/users').then(r=>r.json())]);
        document.getElementById('updated').textContent='更新于 '+new Date().toLocaleTimeString('zh-CN');
        const cards=[['任务总数',stats.total],['总花费','$'+(stats.totalCostUSD||0).toFixed(4)],
          ['平均时长',fmtDur(stats.avgDurationMs||0)],['输出 token',stats.totalOutputTokens||0],
          ['超时/失败',(stats.timeoutCount||0)+'/'+(stats.errorCount||0)]];
        document.getElementById('stats').innerHTML=cards.map(c=>`<div class="card"><div class="n">${c[1]}</div><div class="l">${c[0]}</div></div>`).join('');
        const users=(userPayload&&userPayload.users)||[];
        const ub=document.querySelector('#users tbody');
        ub.innerHTML=users.length?users.map(u=>`<tr>
          <td><span class="tag">${esc(u.platform)}</span></td>
          <td>${esc(u.displayName||u.remoteUserID)}<br><span class="muted">${esc(u.remoteUserID)}</span></td>
          <td>${esc((u.botIDs||[]).join(','))}</td>
          <td>${u.hasSessionID?'可续接':(u.sessionCount>0?'无会话ID':'无')}</td>
          <td>${u.completedProfileCount||0}/${u.profileCount||0}</td>
          <td>${u.fileTaskCount||0}</td>
          <td>${u.taskRecordCount||0}</td>
          <td class="muted">${fmtMaybeTime(u.lastActiveAt||0)}</td>
        </tr>`).join(''):'<tr><td colspan="8" class="empty">还没有远程用户</td></tr>';
        const tb=document.querySelector('#tbl tbody');
        if(!tasks.length){tb.innerHTML='<tr><td colspan="7" class="empty">还没有任务记录 — 用 Telegram / 飞书远程遥控发一条试试</td></tr>';return;}
        tb.innerHTML=tasks.map(t=>`<tr>
          <td class="muted">${fmtTime(t.startedAt)}</td>
          <td><span class="tag">${esc(t.source)}</span><br>${esc(t.initiatorName||t.initiatorID)}</td>
          <td>${esc(t.tool)}</td>
          <td class="q">${esc(t.question)}</td>
          <td class="a">${esc(t.answer)}</td>
          <td>${fmtDur(t.durationMs)}</td>
          <td>${t.costUSD!=null?'$'+t.costUSD.toFixed(4):'<span class=muted>—</span>'}</td>
        </tr>`).join('');
      }catch(e){document.querySelector('#tbl tbody').innerHTML='<tr><td colspan="7" class="empty">加载失败:'+e+'</td></tr>';}
    }
    load();setInterval(load,5000);
    </script></body></html>
    """
}

/// 任务监控协调器:按设置起停内嵌服务,提供记录入口与"打开页面"。单例,主线程访问。
@MainActor
enum TaskMonitor {
    private static var server: MonitorServer?

    /// 当前是否在服务中(开关已挂载)。
    static var isRunning: Bool { server != nil }

    /// 计算前端 dist 目录:相对 app 包定位到兄弟项目 agent-pet-monitor/dist。
    /// app 在当前仓库目录的 AgentPet.app → 兄弟项目在 <上级>/agent-pet-monitor/dist。找不到返回 nil(走内置回退页)。
    static func resolvePluginDir() -> String? {
        let override = Settings.monitorPluginPath
        if !override.isEmpty { return FileManager.default.fileExists(atPath: override) ? override : nil }
        let appDir = (Bundle.main.bundlePath as NSString).deletingLastPathComponent      // 当前仓库目录
        let parent = (appDir as NSString).deletingLastPathComponent                       // .../(上一层)
        let dist = parent + "/agent-pet-monitor/dist"
        return FileManager.default.fileExists(atPath: dist) ? dist : nil
    }

    /// 按当前设置起停:开关开则起服务,关则停。设置变更或启动时调用。
    static func reload() {
        server?.stop()
        server = nil
        guard Settings.monitorEnabled else {
            PetView.log("任务监控未挂载,跳过")
            return
        }
        let s = MonitorServer(port: UInt16(Settings.monitorPort), pluginDir: resolvePluginDir())
        s.start()
        server = s
    }

    /// 记录一轮任务。后台线程可直接调(落盘自带串行队列);只在挂载时记录,关掉就不记。
    static func record(source: String, tool: FeedTool, initiatorID: String, initiatorName: String,
                       cwd: String, question: String, answer: String,
                       startedAt: Date, endedAt: Date, status: String,
                       sessionID: String?, metrics: AgentMetrics?) {
        guard Settings.monitorEnabled else { return }
        let record = TaskRecord(
            id: TaskMonitorStore.makeID(),
            source: source,
            tool: tool == .codex ? "codex" : "claude",
            initiatorID: initiatorID,
            initiatorName: initiatorName,
            cwd: cwd,
            question: question,
            answer: answer,
            startedAt: startedAt.timeIntervalSince1970,
            endedAt: endedAt.timeIntervalSince1970,
            durationMs: Int(endedAt.timeIntervalSince(startedAt) * 1000),
            cliDurationMs: metrics?.cliDurationMs,
            costUSD: metrics?.costUSD,
            inputTokens: metrics?.inputTokens,
            outputTokens: metrics?.outputTokens,
            numTurns: metrics?.numTurns,
            status: status,
            sessionID: sessionID
        )
        TaskMonitorStore.append(record)
    }

    /// 在浏览器打开监控页面。
    static func openInBrowser() {
        guard let url = URL(string: "http://127.0.0.1:\(Settings.monitorPort)/") else { return }
        NSWorkspace.shared.open(url)
    }
}
