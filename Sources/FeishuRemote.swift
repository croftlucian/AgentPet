// MARK: - 远程遥控:飞书(Feishu)长连接接 cc/cx
// 和 Telegram 同款:主公在飞书给机器人发消息 → 桌宠把消息当 prompt 喂给 cc/cx 非交互模式 → 回话与实时进度回传飞书。
// cc(Claude)、cx(Codex)各对应一个飞书企业自建应用(各 app_id + app_secret),各起一条长连接、各维持独立可续接会话。
//
// 复用 RemoteControl.swift 里与传输无关的部件:AgentRunner(跑 cc/cx + 流式解析)、ProgressPanel(进度节流)、
// ChatContext(每会话 cwd/sessionID/busy + 串行队列)、AgentReply、FeedTool。本文件只重写"飞书收/发/编辑消息"这一层。
//
// 收消息走飞书"事件订阅—长连接(WebSocket)"模式:纯出站、无需公网回调,和 Telegram long polling 对称。
// 帧/建连/心跳/回执/分片协议确证自飞书官方 oapi-sdk-go 的 ws 包(pbbp2.Frame、/callback/ws/endpoint),
// 这里用纯 Swift 手写最小 protobuf 实现,零第三方依赖。注意:仅国内版 open.feishu.cn 支持长连接,国际版 Lark 不支持。
//
// 由 build.sh 与 main.swift / RemoteControl.swift 一起 swiftc -swift-version 5 编进同一二进制,共享上述类型。

import Foundation

// MARK: - 最小 protobuf 线格式编解码

/// 飞书长连接帧只用到两种 protobuf wire type:0(varint,整数)与 2(length-delimited,字符串/字节/嵌套 message)。
/// 这里只实现这两种的读写,其余 wire type 解码时按规则跳过,不追求通用 protobuf 能力。
enum Protobuf {
    // MARK: 编码

    /// 写一个无符号 varint(LEB128 变长整数)。
    static func encodeVarint(_ value: UInt64, into data: inout Data) {
        var v = value
        while v >= 0x80 {
            data.append(UInt8(v & 0x7f) | 0x80)
            v >>= 7
        }
        data.append(UInt8(v))
    }

    /// 写字段 tag = field number << 3 | wire type。
    private static func encodeTag(field: Int, wire: Int, into data: inout Data) {
        encodeVarint(UInt64(field << 3 | wire), into: &data)
    }

    /// 写 varint 字段(wire 0)。
    static func encodeVarintField(_ field: Int, _ value: UInt64, into data: inout Data) {
        encodeTag(field: field, wire: 0, into: &data)
        encodeVarint(value, into: &data)
    }

    /// 写 length-delimited 字段(wire 2):tag + 长度前缀 + 原始字节。
    static func encodeBytesField(_ field: Int, _ bytes: Data, into data: inout Data) {
        encodeTag(field: field, wire: 2, into: &data)
        encodeVarint(UInt64(bytes.count), into: &data)
        data.append(bytes)
    }

    /// 写字符串字段(UTF-8 后等价 length-delimited)。
    static func encodeStringField(_ field: Int, _ string: String, into data: inout Data) {
        encodeBytesField(field, Data(string.utf8), into: &data)
    }

    // MARK: 解码

    /// 在 Data 上顺序读取的游标。
    struct Reader {
        let data: Data
        var index: Int
        init(_ data: Data) { self.data = data; self.index = data.startIndex }
        var isAtEnd: Bool { index >= data.endIndex }

        /// 读一个 varint;越界/超 64 位返回 nil。
        mutating func readVarint() -> UInt64? {
            var result: UInt64 = 0
            var shift: UInt64 = 0
            while index < data.endIndex {
                let byte = data[index]
                index += 1
                result |= UInt64(byte & 0x7f) << shift
                if byte & 0x80 == 0 { return result }
                shift += 7
                if shift >= 64 { return nil }
            }
            return nil
        }

        /// 读 length-delimited 的原始字节(先读长度再读内容);越界返回 nil。
        mutating func readBytes() -> Data? {
            guard let len = readVarint() else { return nil }
            let n = Int(len)
            guard n >= 0, index + n <= data.endIndex else { return nil }
            let sub = data.subdata(in: index..<(index + n))
            index += n
            return sub
        }

        /// 跳过一个不关心字段的值;返回 false 表示遇到无法处理的 wire type 或越界,应中止解码。
        mutating func skip(wire: Int) -> Bool {
            switch wire {
            case 0: return readVarint() != nil
            case 2: return readBytes() != nil
            case 5: index += 4; return index <= data.endIndex   // 32-bit 定长
            case 1: index += 8; return index <= data.endIndex   // 64-bit 定长
            default: return false
            }
        }
    }
}

// MARK: - 飞书长连接帧 Frame(对齐 oapi-sdk-go ws/pbbp2.pb.go)

/// 飞书长连接的一帧。字段编号、含义对齐官方 pbbp2.Frame;只承载本场景需要的能力。
struct FeishuFrame {
    var seqID: UInt64 = 0
    var logID: UInt64 = 0
    var service: Int32 = 0
    var method: Int32 = 0            // 0=Control(ping/pong) 1=Data(事件/卡片)
    var headers: [(key: String, value: String)] = []
    var payloadEncoding: String = ""
    var payloadType: String = ""
    var payload: Data = Data()
    var logIDNew: String = ""

    static let methodControl: Int32 = 0
    static let methodData: Int32 = 1

    /// 取某 header 值(线性查找,header 数量很少)。
    func header(_ key: String) -> String? {
        headers.first { $0.key == key }?.value
    }

    /// 编码成 protobuf 字节。字段 1-4、6-7 无条件写(对齐 SDK,proto2 required 不缺失);
    /// headers、payload、logIDNew 非空才写。字段顺序与解码无关,解码端按 tag 识别。
    func encoded() -> Data {
        var data = Data()
        Protobuf.encodeVarintField(1, seqID, into: &data)
        Protobuf.encodeVarintField(2, logID, into: &data)
        Protobuf.encodeVarintField(3, UInt64(bitPattern: Int64(service)), into: &data)
        Protobuf.encodeVarintField(4, UInt64(bitPattern: Int64(method)), into: &data)
        for h in headers {
            var hb = Data()
            Protobuf.encodeStringField(1, h.key, into: &hb)
            Protobuf.encodeStringField(2, h.value, into: &hb)
            Protobuf.encodeBytesField(5, hb, into: &data)
        }
        Protobuf.encodeStringField(6, payloadEncoding, into: &data)
        Protobuf.encodeStringField(7, payloadType, into: &data)
        if !payload.isEmpty { Protobuf.encodeBytesField(8, payload, into: &data) }
        if !logIDNew.isEmpty { Protobuf.encodeStringField(9, logIDNew, into: &data) }
        return data
    }

    /// 从 protobuf 字节解码;遇到格式错误返回 nil。
    static func decode(_ data: Data) -> FeishuFrame? {
        var frame = FeishuFrame()
        var reader = Protobuf.Reader(data)
        while !reader.isAtEnd {
            guard let tag = reader.readVarint() else { return nil }
            let field = Int(tag >> 3)
            let wire = Int(tag & 0x7)
            switch (field, wire) {
            case (1, 0): guard let v = reader.readVarint() else { return nil }; frame.seqID = v
            case (2, 0): guard let v = reader.readVarint() else { return nil }; frame.logID = v
            case (3, 0): guard let v = reader.readVarint() else { return nil }; frame.service = Int32(truncatingIfNeeded: v)
            case (4, 0): guard let v = reader.readVarint() else { return nil }; frame.method = Int32(truncatingIfNeeded: v)
            case (5, 2):
                guard let hb = reader.readBytes(), let header = decodeHeader(hb) else { return nil }
                frame.headers.append(header)
            case (6, 2): guard let b = reader.readBytes() else { return nil }; frame.payloadEncoding = String(decoding: b, as: UTF8.self)
            case (7, 2): guard let b = reader.readBytes() else { return nil }; frame.payloadType = String(decoding: b, as: UTF8.self)
            case (8, 2): guard let b = reader.readBytes() else { return nil }; frame.payload = b
            case (9, 2): guard let b = reader.readBytes() else { return nil }; frame.logIDNew = String(decoding: b, as: UTF8.self)
            default:
                guard reader.skip(wire: wire) else { return nil }
            }
        }
        return frame
    }

    /// 解码一个嵌套的 Header message(key=1, value=2)。
    private static func decodeHeader(_ data: Data) -> (key: String, value: String)? {
        var key = "", value = ""
        var reader = Protobuf.Reader(data)
        while !reader.isAtEnd {
            guard let tag = reader.readVarint() else { return nil }
            let field = Int(tag >> 3)
            let wire = Int(tag & 0x7)
            switch (field, wire) {
            case (1, 2): guard let b = reader.readBytes() else { return nil }; key = String(decoding: b, as: UTF8.self)
            case (2, 2): guard let b = reader.readBytes() else { return nil }; value = String(decoding: b, as: UTF8.self)
            default: guard reader.skip(wire: wire) else { return nil }
            }
        }
        return (key, value)
    }

    /// ping 控制帧(对齐 NewPingFrame):method=Control,带 service,headers 仅 type=ping,无 payload。
    static func ping(service: Int32) -> FeishuFrame {
        var f = FeishuFrame()
        f.method = methodControl
        f.service = service
        f.headers = [(key: "type", value: "ping")]
        return f
    }
}

// MARK: - 飞书 REST(租户 token / 发消息 / 编辑消息)

/// 飞书租户 token 管理 + 消息 REST。一个实例绑一个自建应用(app_id+app_secret)。
/// tenant_access_token 约 2 小时有效,缓存并提前 5 分钟刷新。所有调用同步阻塞,调用方务必在后台线程。
final class FeishuAPI {
    private let appID: String
    private let appSecret: String
    private let base: String                 // 形如 https://open.feishu.cn/open-apis
    private let session: URLSession
    private let lock = NSLock()
    private var cachedToken = ""
    private var tokenExpiry = Date.distantPast

    init(appID: String, appSecret: String, base: String = "https://open.feishu.cn/open-apis") {
        self.appID = appID
        self.appSecret = appSecret
        self.base = base
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 30
        self.session = URLSession(configuration: cfg)
    }

    /// 取有效 token,过期则刷新;失败返回 nil 并记日志。
    func tenantToken() -> String? {
        lock.lock()
        if !cachedToken.isEmpty, Date() < tokenExpiry {
            defer { lock.unlock() }
            return cachedToken
        }
        lock.unlock()

        var req = URLRequest(url: URL(string: base + "/auth/v3/tenant_access_token/internal")!)
        req.httpMethod = "POST"
        req.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: ["app_id": appID, "app_secret": appSecret])
        guard let obj = syncJSON(req), (obj["code"] as? Int) == 0,
              let token = obj["tenant_access_token"] as? String, !token.isEmpty else {
            PetView.log("飞书[token] 获取失败(检查 app_id/app_secret 与应用权限)")
            return nil
        }
        let expire = (obj["expire"] as? Int) ?? 7200
        lock.lock()
        cachedToken = token
        tokenExpiry = Date().addingTimeInterval(TimeInterval(max(60, expire - 300)))
        lock.unlock()
        return token
    }

    /// 发文本消息。receiveIDType 取 "open_id"(私聊回发送者)或 "chat_id"(群里回群)。返回 message_id。
    @discardableResult
    func sendText(receiveID: String, receiveIDType: String, text: String) -> String? {
        guard let token = tenantToken() else { return nil }
        var comps = URLComponents(string: base + "/im/v1/messages")!
        comps.queryItems = [URLQueryItem(name: "receive_id_type", value: receiveIDType)]
        var req = URLRequest(url: comps.url!)
        req.httpMethod = "POST"
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: [
            "receive_id": receiveID,
            "msg_type": "text",
            "content": Self.textContent(text),   // 飞书要求 content 是被字符串化的 JSON
        ])
        guard let obj = syncJSON(req), (obj["code"] as? Int) == 0,
              let data = obj["data"] as? [String: Any], let mid = data["message_id"] as? String else {
            return nil
        }
        return mid
    }

    /// 编辑已发文本消息(进度面板原地刷新用)。成功返回 true。
    @discardableResult
    func editText(messageID: String, text: String) -> Bool {
        guard let token = tenantToken() else { return false }
        var req = URLRequest(url: URL(string: base + "/im/v1/messages/\(messageID)")!)
        req.httpMethod = "PUT"
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: [
            "msg_type": "text",
            "content": Self.textContent(text),
        ])
        return (syncJSON(req)?["code"] as? Int) == 0
    }

    /// 文本消息的 content:飞书要求是 {"text":"…"} 再整体 JSON 字符串化。
    static func textContent(_ text: String) -> String {
        guard let d = try? JSONSerialization.data(withJSONObject: ["text": text]),
              let s = String(data: d, encoding: .utf8) else { return "{\"text\":\"\"}" }
        return s
    }

    private func syncJSON(_ request: URLRequest) -> [String: Any]? {
        let sem = DispatchSemaphore(value: 0)
        var result: [String: Any]?
        let task = session.dataTask(with: request) { data, _, _ in
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

// MARK: - 收到的一条消息(从 im.message.receive_v1 事件解析而来)

/// 解析后的来信。text 已剥离群里的 @ 占位,只留正文。
struct FeishuIncoming {
    let eventID: String        // 幂等去重用
    let senderOpenID: String   // 发送者 open_id(白名单 + 私聊回信目标)
    let chatID: String         // 会话 id(群聊回信目标)
    let chatType: String       // p2p(私聊)/ group(群)
    let messageType: String    // text / image / ...
    let text: String           // 文本正文(已去 @ 占位)
    let mentioned: Bool        // 是否 @ 了人(群里据此决定是否响应)
}

// MARK: - 飞书长连接客户端

/// 一条飞书长连接:建连握手 → URLSessionWebSocketTask 收发 protobuf 帧 → ping 心跳 → 收事件回 200 → 断线重连。
/// 所有连接状态都在串行 connQueue 上读写(URLSession 回调也调度到此队列),无需额外加锁。
/// 收到事件帧时把已合包的事件 JSON 经 onEvent 抛出,并立即回 200 帧(异步处理不阻塞回执,满足飞书 3 秒响应要求)。
final class FeishuLongConn: NSObject, URLSessionWebSocketDelegate {
    private let appID: String
    private let appSecret: String
    private let logTag: String
    private let onEvent: (Data) -> Void

    private let connQueue: DispatchQueue
    private lazy var session: URLSession = {
        let opQueue = OperationQueue()
        opQueue.maxConcurrentOperationCount = 1
        opQueue.underlyingQueue = connQueue   // 所有回调串行落到 connQueue
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 75
        return URLSession(configuration: cfg, delegate: self, delegateQueue: opQueue)
    }()

    private var task: URLSessionWebSocketTask?
    private var running = false
    private var serviceID: Int32 = 0
    private var pingTimer: DispatchSourceTimer?
    private var pingInterval: TimeInterval = 120
    private var reconnectInterval: TimeInterval = 30
    /// 分片缓存:message_id → 各 seq 片(按 sum 预分配,集齐拼接)。
    private var fragments: [String: [Data?]] = [:]

    init(appID: String, appSecret: String, logTag: String, onEvent: @escaping (Data) -> Void) {
        self.appID = appID
        self.appSecret = appSecret
        self.logTag = logTag
        self.onEvent = onEvent
        self.connQueue = DispatchQueue(label: "claudepet.feishu.conn.\(logTag)")
        super.init()
    }

    func start() {
        connQueue.async { [weak self] in
            guard let self = self, !self.running else { return }
            self.running = true
            self.connect()
        }
    }

    func stop() {
        connQueue.async { [weak self] in
            guard let self = self else { return }
            self.running = false
            self.pingTimer?.cancel(); self.pingTimer = nil
            self.task?.cancel(with: .goingAway, reason: nil)
            self.task = nil
            self.fragments.removeAll()
        }
    }

    // MARK: 建连

    /// connQueue 上同步建连:拿 wss 地址 → 起 WebSocket → 收循环 + 心跳。失败则安排重连。
    private func connect() {
        guard running else { return }
        guard let endpoint = fetchEndpoint() else {
            PetView.log("飞书[\(logTag)] 建连失败,稍后重连")
            scheduleReconnect()
            return
        }
        if let pi = endpoint.pingInterval, pi > 0 { pingInterval = TimeInterval(pi) }
        if let ri = endpoint.reconnectInterval, ri > 0 { reconnectInterval = TimeInterval(ri) }
        serviceID = Int32(URLComponents(url: endpoint.url, resolvingAgainstBaseURL: false)?
            .queryItems?.first { $0.name == "service_id" }?.value ?? "") ?? 0

        let t = session.webSocketTask(with: endpoint.url)
        t.maximumMessageSize = 16 * 1024 * 1024
        task = t
        t.resume()
        receiveLoop(t)
        startPing(t)
        PetView.log("飞书[\(logTag)] 长连接已建立(service_id=\(serviceID))")
    }

    private struct EndpointInfo {
        let url: URL
        let pingInterval: Int?
        let reconnectInterval: Int?
    }

    /// POST /callback/ws/endpoint 拿 wss 地址 + 客户端配置(同步)。
    private func fetchEndpoint() -> EndpointInfo? {
        var req = URLRequest(url: URL(string: "https://open.feishu.cn/callback/ws/endpoint")!)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("zh", forHTTPHeaderField: "locale")
        req.httpBody = try? JSONSerialization.data(withJSONObject: ["AppID": appID, "AppSecret": appSecret])

        let sem = DispatchSemaphore(value: 0)
        var body: Data?
        URLSession.shared.dataTask(with: req) { data, _, _ in body = data; sem.signal() }.resume()
        sem.wait()

        guard let data = body,
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        guard (obj["code"] as? Int) == 0, let dict = obj["data"] as? [String: Any],
              let urlStr = dict["URL"] as? String, let url = URL(string: urlStr) else {
            PetView.log("飞书[\(logTag)] endpoint 非 0: \(obj["msg"] as? String ?? "?")")
            return nil
        }
        let cfg = dict["ClientConfig"] as? [String: Any]
        return EndpointInfo(url: url,
                            pingInterval: cfg?["PingInterval"] as? Int,
                            reconnectInterval: cfg?["ReconnectInterval"] as? Int)
    }

    // MARK: 收发

    /// 递归接收:每收到一条二进制消息解析一帧,再继续收;失败则触发重连。
    private func receiveLoop(_ t: URLSessionWebSocketTask) {
        t.receive { [weak self] result in
            guard let self = self else { return }
            switch result {
            case .success(let message):
                if case .data(let d) = message { self.handleFrame(d, on: t) }
                guard self.running, self.task === t else { return }
                self.receiveLoop(t)
            case .failure:
                self.handleDisconnect(t)
            }
        }
    }

    /// 按 pingInterval 在 connQueue 周期发应用层 ping 帧(非 WebSocket 协议层 ping)。
    private func startPing(_ t: URLSessionWebSocketTask) {
        pingTimer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: connQueue)
        timer.schedule(deadline: .now() + pingInterval, repeating: pingInterval)
        timer.setEventHandler { [weak self] in
            guard let self = self, self.task === t else { return }
            t.send(.data(FeishuFrame.ping(service: self.serviceID).encoded())) { err in
                if let err = err { PetView.log("飞书[\(self.logTag)] ping 失败: \(err.localizedDescription)") }
            }
        }
        pingTimer = timer
        timer.resume()
    }

    /// 解析一帧:control 帧只处理 pong(可能携带新配置);data 帧合包后,event 类型抛给 onEvent 并回 200。
    private func handleFrame(_ data: Data, on t: URLSessionWebSocketTask) {
        guard let frame = FeishuFrame.decode(data) else {
            PetView.log("飞书[\(logTag)] 帧解码失败")
            return
        }
        switch frame.method {
        case FeishuFrame.methodControl:
            if frame.header("type") == "pong", !frame.payload.isEmpty,
               let cfg = try? JSONSerialization.jsonObject(with: frame.payload) as? [String: Any] {
                if let pi = cfg["PingInterval"] as? Int, pi > 0 {
                    pingInterval = TimeInterval(pi)
                    startPing(t)
                }
            }
        case FeishuFrame.methodData:
            guard let payload = reassemble(frame) else { return }   // 等待更多分片
            if frame.header("type") == "event" { onEvent(payload) }
            sendAck(frame, on: t)   // 无论处理结果,立即回 200,避免飞书重推
        default:
            break
        }
    }

    /// 分片合包:sum<=1 直接返回 payload;否则按 message_id 收齐所有 seq 片再拼接,未齐返回 nil。
    private func reassemble(_ frame: FeishuFrame) -> Data? {
        let sum = Int(frame.header("sum") ?? "1") ?? 1
        if sum <= 1 { return frame.payload }
        let msgID = frame.header("message_id") ?? ""
        let seq = Int(frame.header("seq") ?? "0") ?? 0
        guard !msgID.isEmpty, seq >= 0, seq < sum else { return frame.payload }

        var buf = fragments[msgID] ?? Array(repeating: nil, count: sum)
        if buf.count != sum { buf = Array(repeating: nil, count: sum) }
        buf[seq] = frame.payload
        if buf.contains(where: { $0 == nil }) {
            fragments[msgID] = buf
            return nil
        }
        fragments.removeValue(forKey: msgID)
        return buf.compactMap { $0 }.reduce(Data(), +)
    }

    /// 回执:复用收到的帧,payload 换成 {"code":200},发回。
    private func sendAck(_ frame: FeishuFrame, on t: URLSessionWebSocketTask) {
        var ack = frame
        ack.payload = Data("{\"code\":200}".utf8)
        t.send(.data(ack.encoded())) { _ in }
    }

    // MARK: 重连

    private func handleDisconnect(_ t: URLSessionWebSocketTask) {
        guard task === t else { return }   // 过期回调忽略
        pingTimer?.cancel(); pingTimer = nil
        task = nil
        fragments.removeAll()
        guard running else { return }
        PetView.log("飞书[\(logTag)] 连接断开,\(Int(reconnectInterval))s 后重连")
        scheduleReconnect()
    }

    private func scheduleReconnect() {
        guard running else { return }
        connQueue.asyncAfter(deadline: .now() + reconnectInterval) { [weak self] in
            guard let self = self, self.running, self.task == nil else { return }
            self.connect()
        }
    }
}

// MARK: - 飞书机器人:把来信喂给 cc/cx,回话与进度回传

/// 一个飞书机器人:绑定一个应用 + 一个 tool(cc 或 cx)。长连接收消息 → 解析/去重/白名单/指令 → 喂 AgentRunner → 回话。
/// 按"回信目标"(私聊=发送者 open_id,群=chat_id)各建一份 ChatContext:同一会话串行续接,不同会话并行互不阻塞。
final class FeishuBot {
    private let tool: FeedTool
    private let home: String
    private let allowedOpenIDs: Set<String>
    private let onActivity: (FeedTool, String, String?) -> Void
    private let api: FeishuAPI
    private var conn: FeishuLongConn!

    /// 进度面板最多原地编辑次数:飞书对单条消息编辑次数有限,撞限即停刷新,最终正文照样另发。
    private static let maxProgressEdits = 18

    private var contexts: [String: ChatContext] = [:]   // 仅长连接事件回调线程访问
    private var seenEventIDs: [String] = []             // 幂等去重(FIFO,最多 200)

    init(appID: String, appSecret: String, tool: FeedTool, home: String,
         allowedOpenIDs: Set<String>, onActivity: @escaping (FeedTool, String, String?) -> Void) {
        self.tool = tool
        self.home = home
        self.allowedOpenIDs = allowedOpenIDs
        self.onActivity = onActivity
        self.api = FeishuAPI(appID: appID, appSecret: appSecret)
        let tag = tool == .codex ? "cx" : "cc"
        self.conn = FeishuLongConn(appID: appID, appSecret: appSecret, logTag: tag) { [weak self] payload in
            self?.handleEvent(payload)
        }
    }

    func start() {
        conn.start()
        PetView.log("飞书[\(tool.label)] 机器人启动,默认目录 \(home)")
    }

    func stop() { conn.stop() }

    // MARK: 事件分发(在长连接 connQueue 串行执行,故 contexts/seenEventIDs 无需加锁)

    /// 解析来信 → 去重 → 白名单 → 群里需 @ → 指令 or 喂 agent。本方法须快速返回(重活派后台),好让长连接尽快回 200。
    private func handleEvent(_ payload: Data) {
        guard let inc = Self.parse(payload: payload) else { return }
        if isDuplicate(inc.eventID) { return }

        // 白名单:非空时只认名单内 open_id;空名单放行并记日志提醒。
        if !allowedOpenIDs.isEmpty, !allowedOpenIDs.contains(inc.senderOpenID) {
            PetView.log("飞书[\(tool.label)] 拒收 open_id \(inc.senderOpenID)(不在白名单)")
            replyAsync(inc, "你不在白名单里,无法下发指令。")
            return
        }
        if allowedOpenIDs.isEmpty {
            PetView.log("飞书[\(tool.label)] 警告:未设白名单,open_id \(inc.senderOpenID) 已放行")
        }

        // 群里不 @ 就不响应,避免群消息全触发;私聊一律响应。
        if inc.chatType != "p2p", !inc.mentioned { return }

        guard inc.messageType == "text" else {
            replyAsync(inc, "暂时只认文字消息。")
            return
        }
        let text = inc.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }

        let ctx = context(for: inc)
        if text.hasPrefix("/") {
            handleCommand(text, inc: inc, ctx: ctx)
            return
        }
        guard ctx.tryBegin() else {
            replyAsync(inc, "上一条还在跑,等它答完再发哈。")
            return
        }
        runAgent(prompt: text, inc: inc, ctx: ctx)
    }

    private func isDuplicate(_ id: String) -> Bool {
        guard !id.isEmpty else { return false }
        if seenEventIDs.contains(id) { return true }
        seenEventIDs.append(id)
        if seenEventIDs.count > 200 { seenEventIDs.removeFirst() }
        return false
    }

    /// 取该会话的状态,没有就按默认目录新建。会话键:私聊按发送者、群按 chat_id。
    private func context(for inc: FeishuIncoming) -> ChatContext {
        let key = inc.chatType == "p2p" ? "u:" + inc.senderOpenID : "c:" + inc.chatID
        if let ctx = contexts[key] { return ctx }
        let tag = tool == .codex ? "cx" : "cc"
        let ctx = ChatContext(tool: tool, cwd: home, label: "claudepet.feishu.\(tag).\(key)")
        contexts[key] = ctx
        return ctx
    }

    // MARK: 指令(/cd /pwd /new /help)——只动该会话自己的状态

    private func handleCommand(_ text: String, inc: FeishuIncoming, ctx: ChatContext) {
        let parts = text.split(separator: " ", maxSplits: 1).map(String.init)
        let cmd = parts[0].lowercased()
        let arg = parts.count > 1 ? parts[1].trimmingCharacters(in: .whitespaces) : ""
        switch cmd {
        case "/cd":
            let expanded = (arg as NSString).expandingTildeInPath
            var isDir: ObjCBool = false
            guard !arg.isEmpty, FileManager.default.fileExists(atPath: expanded, isDirectory: &isDir), isDir.boolValue else {
                replyAsync(inc, "目录不存在:\(arg.isEmpty ? "(空)" : arg)")
                return
            }
            ctx.setCwd(expanded)
            ctx.setSessionID(nil)
            replyAsync(inc, "已切到 \(expanded),并开了新会话。")
        case "/pwd":
            replyAsync(inc, "当前目录:\(ctx.cwd)")
        case "/new":
            ctx.setSessionID(nil)
            replyAsync(inc, "已开新会话,之前的上下文清空。")
        case "/help", "/start":
            replyAsync(inc, """
            我是 \(tool.label) 远程遥控(飞书)。直接发消息我就替你干活;群里需 @ 我。支持:
            /cd <路径>  切换工作目录(并开新会话)
            /pwd        看当前目录
            /new        开新会话(清上下文)
            /help       这条帮助
            当前目录:\(ctx.cwd)
            """)
        default:
            replyAsync(inc, "不认得指令 \(cmd),发 /help 看用法。")
        }
    }

    // MARK: 跑 agent

    /// 把消息当 prompt 喂给 cc/cx:派到该会话串行队列后台跑。流程对齐 Telegram:
    /// 桌宠开跑 → 占一条进度消息 → 边跑边原地编辑刷新(限次)→ 写回会话 id、解忙 → 收尾进度 + 另发最终正文 → 桌宠收工。
    private func runAgent(prompt: String, inc: FeishuIncoming, ctx: ChatContext) {
        let tool = self.tool
        ctx.queue.async { [weak self] in
            guard let self = self else { return }
            DispatchQueue.main.async { self.onActivity(tool, "start", nil) }
            PetView.log("飞书[\(tool.label)] 收到 \(prompt.count) 字,开跑")
            let startedAt = Date()   // 墙钟计时起点:供任务监控算运行时长

            let panelID = self.reply(inc, "🤖 收到,开跑…")
            let panel = ProgressPanel(title: "\(tool.label) 远程进度", minInterval: 3.0)
            var edits = 0

            let snap = ctx.snapshot()
            let reply = AgentRunner.run(tool: tool, prompt: prompt, sessionID: snap.sessionID,
                                        cwd: snap.cwd, ioTag: inc.eventID.isEmpty ? inc.senderOpenID : inc.eventID) { [weak self] line in
                guard let self = self, let panelID = panelID, edits < Self.maxProgressEdits else { return }
                panel.append(line)
                if panel.shouldFlush() {
                    if self.api.editText(messageID: panelID, text: panel.render()) { edits += 1 }
                }
            }
            ctx.setSessionID(reply.sessionID)
            ctx.end()

            // 任务监控:落盘本轮"问题→答案"连同发起人(飞书 open_id)、耗时、花费(开关关时内部跳过)。
            DispatchQueue.main.async {
                TaskMonitor.record(source: "feishu", tool: tool, initiatorID: inc.senderOpenID,
                                   initiatorName: inc.senderOpenID, cwd: snap.cwd, question: prompt,
                                   answer: reply.text, startedAt: startedAt, endedAt: Date(),
                                   status: reply.status, sessionID: reply.sessionID, metrics: reply.metrics)
            }

            if let panelID = panelID, edits < Self.maxProgressEdits {
                _ = self.api.editText(messageID: panelID, text: panel.renderDone())
            }
            // 最终正文另发(可能长文,按飞书上限切段,复用纯文本切段逻辑)。
            for chunk in TelegramBot.chunks(reply.text, limit: 4000) {
                _ = self.reply(inc, chunk)
            }
            let summary = reply.text.split(whereSeparator: \.isNewline).first.map(String.init) ?? reply.text
            DispatchQueue.main.async { self.onActivity(tool, "done", String(summary.prefix(40))) }
        }
    }

    // MARK: 回话

    /// 回到来信现场:私聊回发送者 open_id,群里回 chat_id。返回 message_id。
    @discardableResult
    private func reply(_ inc: FeishuIncoming, _ text: String) -> String? {
        if inc.chatType == "p2p" {
            return api.sendText(receiveID: inc.senderOpenID, receiveIDType: "open_id", text: text)
        }
        return api.sendText(receiveID: inc.chatID, receiveIDType: "chat_id", text: text)
    }

    /// 后台回话(用于事件分发线程,避免阻塞回执)。
    private func replyAsync(_ inc: FeishuIncoming, _ text: String) {
        DispatchQueue.global().async { [weak self] in _ = self?.reply(inc, text) }
    }

    // MARK: 事件解析(static,供离线自测)

    /// 从 im.message.receive_v1 事件 JSON 解析来信;非该事件或缺字段返回 nil。
    static func parse(payload: Data) -> FeishuIncoming? {
        guard let obj = try? JSONSerialization.jsonObject(with: payload) as? [String: Any] else { return nil }
        let header = obj["header"] as? [String: Any]
        let eventID = header?["event_id"] as? String ?? ""
        guard (header?["event_type"] as? String) == "im.message.receive_v1",
              let event = obj["event"] as? [String: Any],
              let message = event["message"] as? [String: Any] else { return nil }

        let openID = ((event["sender"] as? [String: Any])?["sender_id"] as? [String: Any])?["open_id"] as? String ?? ""
        let chatID = message["chat_id"] as? String ?? ""
        let chatType = message["chat_type"] as? String ?? "p2p"
        let msgType = message["message_type"] as? String ?? ""
        let mentions = message["mentions"] as? [[String: Any]] ?? []

        var text = ""
        if msgType == "text", let cstr = message["content"] as? String,
           let cdata = cstr.data(using: .utf8),
           let cobj = try? JSONSerialization.jsonObject(with: cdata) as? [String: Any] {
            text = cobj["text"] as? String ?? ""
        }
        return FeishuIncoming(eventID: eventID, senderOpenID: openID, chatID: chatID,
                              chatType: chatType, messageType: msgType,
                              text: stripMentions(text), mentioned: !mentions.isEmpty)
    }

    /// 去掉飞书文本里的 @ 占位(@_user_N / @_all),并收拢多余空白。
    static func stripMentions(_ s: String) -> String {
        var r = s.replacingOccurrences(of: #"@_user_\d+"#, with: "", options: .regularExpression)
        r = r.replacingOccurrences(of: "@_all", with: "")
        return r.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
