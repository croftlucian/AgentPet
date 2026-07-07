import AppKit

struct RemoteUserSummary {
    var platform: String
    var remoteUserID: String
    var displayName: String
    var botIDs: [String]
    var profileCount: Int
    var completedProfileCount: Int
    var sessionCount: Int
    var cwd: String
    var hasSessionID: Bool
    var recentFileTaskID: String
    var fileTaskCount: Int
    var taskRecordCount: Int
    var allowlisted: Bool
    var lastActiveAt: Double
    var fileDirectory: URL?

    var botText: String { botIDs.isEmpty ? "无" : botIDs.joined(separator: ",") }
    var sessionText: String { hasSessionID ? "可续接" : (sessionCount > 0 ? "无会话ID" : "无") }
    var profileText: String { "\(completedProfileCount)/\(profileCount)" }
    var lastActiveText: String {
        guard lastActiveAt > 0 else { return "无" }
        let formatter = DateFormatter()
        formatter.dateFormat = "MM-dd HH:mm"
        return formatter.string(from: Date(timeIntervalSince1970: lastActiveAt))
    }
}

enum RemoteUserAdmin {
    private struct Builder {
        var platform: String
        var remoteUserID: String
        var displayName = ""
        var botIDs = Set<String>()
        var profileCount = 0
        var completedProfileCount = 0
        var sessionCount = 0
        var cwd = ""
        var hasSessionID = false
        var recentFileTaskID = ""
        var fileTaskCount = 0
        var taskRecordCount = 0
        var allowlisted = false
        var lastActiveAt: Double = 0
        var fileDirectory: URL?
    }

    static func summaries() -> [RemoteUserSummary] {
        var builders: [String: Builder] = [:]
        func key(_ platform: String, _ remoteUserID: String) -> String { platform + "|" + remoteUserID }
        func load(_ platform: String, _ remoteUserID: String) -> Builder {
            builders[key(platform, remoteUserID)] ?? Builder(platform: platform, remoteUserID: remoteUserID)
        }
        func save(_ builder: Builder) { builders[key(builder.platform, builder.remoteUserID)] = builder }

        for profile in RemoteBotProfileStore.allRecords() {
            var b = load(profile.platform, profile.remoteUserID)
            b.botIDs.insert(profile.botID)
            b.profileCount += 1
            if profile.isCompleted { b.completedProfileCount += 1 }
            b.lastActiveAt = max(b.lastActiveAt, profile.updatedAt)
            save(b)
        }

        for session in RemoteSessionStore.allRecords() {
            var b = load(session.platform, session.remoteUserID)
            b.botIDs.insert(session.botID)
            b.sessionCount += 1
            if !session.cwd.isEmpty { b.cwd = session.cwd }
            if session.sessionID?.isEmpty == false { b.hasSessionID = true }
            if let taskID = session.recentFileTaskID, !taskID.isEmpty { b.recentFileTaskID = taskID }
            b.lastActiveAt = max(b.lastActiveAt, session.updatedAt)
            save(b)
        }

        for record in TaskMonitorStore.readAll() {
            var b = load(record.source, record.initiatorID)
            if !record.initiatorName.isEmpty { b.displayName = record.initiatorName }
            b.taskRecordCount += 1
            b.lastActiveAt = max(b.lastActiveAt, record.endedAt)
            save(b)
        }

        for info in fileTaskStats() {
            var b = load(info.platform, info.remoteUserID)
            b.botIDs.insert(info.botID)
            b.fileTaskCount += info.count
            if b.recentFileTaskID.isEmpty { b.recentFileTaskID = info.latestTaskID }
            b.lastActiveAt = max(b.lastActiveAt, info.latestActivity)
            b.fileDirectory = info.userDirectory
            save(b)
        }

        for id in Settings.telegramAllowedChatIDSet {
            var b = load("telegram", id)
            b.allowlisted = true
            save(b)
        }

        for id in Settings.feishuAllowedOpenIDSet {
            var b = load("feishu", id)
            b.allowlisted = true
            save(b)
        }

        return builders.values.map { b in
            RemoteUserSummary(platform: b.platform,
                              remoteUserID: b.remoteUserID,
                              displayName: b.displayName.isEmpty ? b.remoteUserID : b.displayName,
                              botIDs: b.botIDs.sorted(),
                              profileCount: b.profileCount,
                              completedProfileCount: b.completedProfileCount,
                              sessionCount: b.sessionCount,
                              cwd: b.cwd,
                              hasSessionID: b.hasSessionID,
                              recentFileTaskID: b.recentFileTaskID,
                              fileTaskCount: b.fileTaskCount,
                              taskRecordCount: b.taskRecordCount,
                              allowlisted: b.allowlisted,
                              lastActiveAt: b.lastActiveAt,
                              fileDirectory: b.fileDirectory)
        }.sorted {
            if $0.lastActiveAt != $1.lastActiveAt { return $0.lastActiveAt > $1.lastActiveAt }
            return ($0.platform, $0.remoteUserID) < ($1.platform, $1.remoteUserID)
        }
    }

    static func monitorRows() -> [[String: Any]] {
        summaries().map { user in
            [
                "platform": user.platform,
                "remoteUserID": user.remoteUserID,
                "displayName": user.displayName,
                "botIDs": user.botIDs,
                "profileCount": user.profileCount,
                "completedProfileCount": user.completedProfileCount,
                "sessionCount": user.sessionCount,
                "cwd": user.cwd,
                "hasSessionID": user.hasSessionID,
                "recentFileTaskID": user.recentFileTaskID,
                "fileTaskCount": user.fileTaskCount,
                "taskRecordCount": user.taskRecordCount,
                "allowlisted": user.allowlisted,
                "lastActiveAt": user.lastActiveAt,
                "fileDirectory": user.fileDirectory?.path ?? ""
            ]
        }
    }

    static func clearSessions(for user: RemoteUserSummary) {
        for botID in user.botIDs {
            RemoteSessionStore.remove(platform: user.platform, remoteUserID: user.remoteUserID, botID: botID)
        }
    }

    static func clearSessions(platform: String, remoteUserID: String) -> Bool {
        let records = RemoteSessionStore.allRecords().filter { $0.platform == platform && $0.remoteUserID == remoteUserID }
        for record in records {
            RemoteSessionStore.remove(platform: record.platform, remoteUserID: record.remoteUserID, botID: record.botID)
        }
        return true
    }

    static func clearProfiles(for user: RemoteUserSummary) {
        for botID in user.botIDs {
            RemoteBotProfileStore.remove(platform: user.platform, remoteUserID: user.remoteUserID, botID: botID)
        }
    }

    static func clearProfiles(platform: String, remoteUserID: String) -> Bool {
        let records = RemoteBotProfileStore.allRecords().filter { $0.platform == platform && $0.remoteUserID == remoteUserID }
        for record in records {
            RemoteBotProfileStore.remove(platform: record.platform, remoteUserID: record.remoteUserID, botID: record.botID)
        }
        return true
    }

    static func addAllowlist(platform: String, remoteUserID: String) -> Bool {
        addUser(platform: platform, remoteUserID: remoteUserID, tool: "", telegramBotToken: "",
                feishuAppID: "", feishuAppSecret: "")
    }

    static func addUser(platform: String, remoteUserID: String, tool: String, telegramBotToken: String,
                        feishuAppID: String, feishuAppSecret: String) -> Bool {
        let id = remoteUserID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty else { return false }
        let selectedTools = normalizedTools(tool)
        switch platform.lowercased() {
        case "telegram":
            Settings.telegramAllowedChatIDs = appendingID(id, to: Settings.telegramAllowedChatIDs)
            let token = telegramBotToken.trimmingCharacters(in: .whitespacesAndNewlines)
            if !token.isEmpty {
                if selectedTools.contains("claude") {
                    Settings.telegramClaudeToken = appendingID(token, to: Settings.telegramClaudeToken)
                }
                if selectedTools.contains("codex") {
                    Settings.telegramCodexToken = appendingID(token, to: Settings.telegramCodexToken)
                }
            }
        case "feishu":
            Settings.feishuAllowedOpenIDs = appendingID(id, to: Settings.feishuAllowedOpenIDs)
            let appID = feishuAppID.trimmingCharacters(in: .whitespacesAndNewlines)
            let appSecret = feishuAppSecret.trimmingCharacters(in: .whitespacesAndNewlines)
            if !appID.isEmpty { assignFeishuAppID(appID, tools: selectedTools) }
            if !appSecret.isEmpty { assignFeishuAppSecret(appSecret, tools: selectedTools) }
        default:
            return false
        }
        Settings.remoteEnabled = true
        DispatchQueue.main.async { RemoteControl.shared.reload() }
        return true
    }

    static func removeAllowlist(platform: String, remoteUserID: String) {
        switch platform.lowercased() {
        case "telegram":
            Settings.telegramAllowedChatIDs = removingID(remoteUserID, from: Settings.telegramAllowedChatIDs)
        case "feishu":
            Settings.feishuAllowedOpenIDs = removingID(remoteUserID, from: Settings.feishuAllowedOpenIDs)
        default:
            return
        }
        DispatchQueue.main.async { RemoteControl.shared.reload() }
    }

    static func deleteFiles(platform: String, remoteUserID: String) -> Int {
        let base = RemoteFileTask.defaultBaseDirectory()
        let safePlatform = RemoteFileTask.sanitizePathSegment(platform, fallback: "")
        let safeUser = RemoteFileTask.sanitizePathSegment(remoteUserID, fallback: "")
        guard !safePlatform.isEmpty, !safeUser.isEmpty else { return -1 }
        let platformURL = base.appendingPathComponent(safePlatform, isDirectory: true)
        guard let bots = try? FileManager.default.contentsOfDirectory(at: platformURL, includingPropertiesForKeys: [.isDirectoryKey]) else {
            return 0
        }
        var removed = 0
        for botURL in bots where isDirectory(botURL) {
            let userURL = botURL.appendingPathComponent(safeUser, isDirectory: true)
            if FileManager.default.fileExists(atPath: userURL.path) {
                try? FileManager.default.removeItem(at: userURL)
                removed += 1
            }
        }
        return removed
    }

    static func deleteUser(platform: String, remoteUserID: String, removeAllowlist: Bool, deleteFiles shouldDeleteFiles: Bool,
                           deleteTasks: Bool) -> [String: Any] {
        guard !platform.isEmpty, !remoteUserID.isEmpty else { return ["ok": false, "error": "缺少用户参数"] }
        _ = clearSessions(platform: platform, remoteUserID: remoteUserID)
        _ = clearProfiles(platform: platform, remoteUserID: remoteUserID)
        if removeAllowlist { RemoteUserAdmin.removeAllowlist(platform: platform, remoteUserID: remoteUserID) }
        let fileDirs = shouldDeleteFiles ? deleteFiles(platform: platform, remoteUserID: remoteUserID) : 0
        let taskRows = deleteTasks ? TaskMonitorStore.removeRecords(source: platform, initiatorID: remoteUserID) : 0
        return ["ok": true, "fileDirectoriesRemoved": fileDirs, "taskRecordsRemoved": taskRows, "users": monitorRows()]
    }

    private static func appendingID(_ id: String, to raw: String) -> String {
        var ids = splitIDs(raw)
        if !ids.contains(id) { ids.append(id) }
        return ids.joined(separator: ",")
    }

    private static func removingID(_ id: String, from raw: String) -> String {
        splitIDs(raw).filter { $0 != id }.joined(separator: ",")
    }

    private static func splitIDs(_ raw: String) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for id in raw.split(whereSeparator: { $0 == "," || $0 == " " || $0 == "\n" || $0 == "\t" }).map(String.init) {
            guard !id.isEmpty, !seen.contains(id) else { continue }
            seen.insert(id)
            result.append(id)
        }
        return result
    }

    private static func normalizedTools(_ tool: String) -> Set<String> {
        switch tool.lowercased() {
        case "claude": return ["claude"]
        case "codex": return ["codex"]
        default: return ["claude", "codex"]
        }
    }

    private static func assignFeishuAppID(_ appID: String, tools: Set<String>) {
        if tools.contains("claude") { Settings.feishuClaudeAppID = appID }
        if tools.contains("codex") { Settings.feishuCodexAppID = appID }
    }

    private static func assignFeishuAppSecret(_ appSecret: String, tools: Set<String>) {
        if tools.contains("claude") { Settings.feishuClaudeAppSecret = appSecret }
        if tools.contains("codex") { Settings.feishuCodexAppSecret = appSecret }
    }

    private struct FileTaskInfo {
        let platform: String
        let botID: String
        let remoteUserID: String
        let count: Int
        let latestTaskID: String
        let latestActivity: Double
        let userDirectory: URL
    }

    private static func fileTaskStats() -> [FileTaskInfo] {
        let base = RemoteFileTask.defaultBaseDirectory()
        guard let platforms = try? FileManager.default.contentsOfDirectory(at: base, includingPropertiesForKeys: [.isDirectoryKey]) else {
            return []
        }
        var result: [FileTaskInfo] = []
        for platformURL in platforms where isDirectory(platformURL) {
            guard let bots = try? FileManager.default.contentsOfDirectory(at: platformURL, includingPropertiesForKeys: [.isDirectoryKey]) else { continue }
            for botURL in bots where isDirectory(botURL) {
                guard let users = try? FileManager.default.contentsOfDirectory(at: botURL, includingPropertiesForKeys: [.isDirectoryKey]) else { continue }
                for userURL in users where isDirectory(userURL) {
                    guard let tasks = try? FileManager.default.contentsOfDirectory(at: userURL, includingPropertiesForKeys: [.isDirectoryKey, .contentModificationDateKey]) else { continue }
                    let taskDirs = tasks.filter {
                        isDirectory($0) && FileManager.default.fileExists(atPath: $0.appendingPathComponent("meta.json").path)
                    }
                    guard let latest = taskDirs.max(by: { activityTime($0) < activityTime($1) }) else { continue }
                    result.append(FileTaskInfo(platform: platformURL.lastPathComponent,
                                               botID: botURL.lastPathComponent,
                                               remoteUserID: userURL.lastPathComponent,
                                               count: taskDirs.count,
                                               latestTaskID: latest.lastPathComponent,
                                               latestActivity: activityTime(latest),
                                               userDirectory: userURL))
                }
            }
        }
        return result
    }

    private static func isDirectory(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
    }

    private static func activityTime(_ url: URL) -> Double {
        ((try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? Date.distantPast).timeIntervalSince1970
    }
}

@MainActor
final class RemoteUserManagerWindowController: NSWindowController, NSTableViewDataSource, NSTableViewDelegate {
    private var users: [RemoteUserSummary] = []
    private let table = NSTableView()
    private let detail = NSTextView(frame: .zero)

    init() {
        let content = NSView(frame: NSRect(x: 0, y: 0, width: 760, height: 520))
        let window = NSWindow(contentRect: content.frame, styleMask: [.titled, .closable, .resizable],
                              backing: .buffered, defer: false)
        window.title = "远程用户管理"
        window.isReleasedWhenClosed = false
        window.contentView = content
        super.init(window: window)
        buildContent(content)
        reload()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("不支持 Interface Builder 加载") }

    private func buildContent(_ content: NSView) {
        let scroll = NSScrollView(frame: NSRect(x: 16, y: 132, width: 728, height: 332))
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        table.headerView = NSTableHeaderView()
        table.dataSource = self
        table.delegate = self
        table.rowHeight = 26
        addColumn("platform", "平台", 70)
        addColumn("user", "用户", 150)
        addColumn("name", "名称", 120)
        addColumn("bots", "Bot", 120)
        addColumn("session", "会话", 80)
        addColumn("files", "文件任务", 80)
        addColumn("last", "最后活动", 100)
        scroll.documentView = table
        content.addSubview(scroll)

        let detailScroll = NSScrollView(frame: NSRect(x: 16, y: 48, width: 728, height: 72))
        detailScroll.hasVerticalScroller = true
        detailScroll.borderType = .bezelBorder
        detail.isEditable = false
        detail.isSelectable = true
        detail.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        detail.textContainerInset = NSSize(width: 8, height: 6)
        detailScroll.documentView = detail
        content.addSubview(detailScroll)

        button("刷新", x: 16, width: 74, action: #selector(refresh(_:)), content: content)
        button("清除会话", x: 102, width: 90, action: #selector(clearSession(_:)), content: content)
        button("清除设置", x: 204, width: 90, action: #selector(clearProfile(_:)), content: content)
        button("打开文件目录", x: 306, width: 104, action: #selector(openFiles(_:)), content: content)
        button("打开监控", x: 422, width: 86, action: #selector(openMonitor(_:)), content: content)
        let note = NSTextField(labelWithString: "清除会话只断开续聊,不删除任务文件；清除设置会让该用户下次重新做 Bot 个性化设置。")
        note.textColor = .secondaryLabelColor
        note.font = .systemFont(ofSize: 11)
        note.frame = NSRect(x: 520, y: 18, width: 224, height: 24)
        content.addSubview(note)
    }

    private func addColumn(_ id: String, _ title: String, _ width: CGFloat) {
        let col = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(id))
        col.title = title
        col.width = width
        table.addTableColumn(col)
    }

    private func button(_ title: String, x: CGFloat, width: CGFloat, action: Selector, content: NSView) {
        let b = NSButton(title: title, target: self, action: action)
        b.bezelStyle = .rounded
        b.frame = NSRect(x: x, y: 16, width: width, height: 26)
        content.addSubview(b)
    }

    private func reload() {
        users = RemoteUserAdmin.summaries()
        table.reloadData()
        if users.isEmpty {
            detail.string = "暂无远程用户。启用远程遥控后,Telegram / 飞书用户发过消息会出现在这里。"
        } else {
            let row = min(max(table.selectedRow, 0), users.count - 1)
            table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            updateDetail(row: row)
        }
    }

    func numberOfRows(in tableView: NSTableView) -> Int { users.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let id = tableColumn?.identifier.rawValue ?? ""
        let cellID = NSUserInterfaceItemIdentifier("remote-user-cell-\(id)")
        let cell = tableView.makeView(withIdentifier: cellID, owner: self) as? NSTableCellView ?? NSTableCellView()
        cell.identifier = cellID
        let label = cell.textField ?? NSTextField(labelWithString: "")
        label.lineBreakMode = .byTruncatingTail
        label.frame = NSRect(x: 6, y: 3, width: (tableColumn?.width ?? 80) - 10, height: 20)
        if label.superview == nil {
            cell.addSubview(label)
            cell.textField = label
        }
        let user = users[row]
        switch id {
        case "platform": label.stringValue = user.platform
        case "user": label.stringValue = user.remoteUserID
        case "name": label.stringValue = user.displayName
        case "bots": label.stringValue = user.botText
        case "session": label.stringValue = user.sessionText
        case "files": label.stringValue = "\(user.fileTaskCount)"
        case "last": label.stringValue = user.lastActiveText
        default: label.stringValue = ""
        }
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) { updateDetail(row: table.selectedRow) }

    private func selectedUser() -> RemoteUserSummary? {
        let row = table.selectedRow
        guard row >= 0, row < users.count else { return nil }
        return users[row]
    }

    private func updateDetail(row: Int) {
        guard row >= 0, row < users.count else { return }
        let u = users[row]
        detail.string = """
        平台: \(u.platform)    用户: \(u.remoteUserID)    名称: \(u.displayName)
        Bot: \(u.botText)    个性化设置: \(u.profileText)    会话: \(u.sessionText)
        工作目录: \(u.cwd.isEmpty ? "无" : u.cwd)
        最近文件任务: \(u.recentFileTaskID.isEmpty ? "无" : u.recentFileTaskID)    文件任务数: \(u.fileTaskCount)    任务记录数: \(u.taskRecordCount)
        """
    }

    @objc private func refresh(_ sender: Any?) { reload() }

    @objc private func clearSession(_ sender: Any?) {
        guard let user = selectedUser() else { return }
        RemoteUserAdmin.clearSessions(for: user)
        reload()
    }

    @objc private func clearProfile(_ sender: Any?) {
        guard let user = selectedUser() else { return }
        RemoteUserAdmin.clearProfiles(for: user)
        reload()
    }

    @objc private func openFiles(_ sender: Any?) {
        guard let url = selectedUser()?.fileDirectory else { return }
        NSWorkspace.shared.open(url)
    }

    @objc private func openMonitor(_ sender: Any?) {
        if !Settings.monitorEnabled {
            Settings.monitorEnabled = true
            TaskMonitor.reload()
        }
        TaskMonitor.openInBrowser()
    }
}
