import AppKit
import ApplicationServices
import ServiceManagement // SMAppService:开机自启,macOS 13+
import Carbon.HIToolbox // RegisterEventHotKey 等:注册全局快捷键,无需辅助功能权限

// MARK: - 外观与动画参数
// 集中放置便于调校,避免散落在各处的“魔法数字”
private enum Style {
    /// 当前星芒主色。手动模式取用户设置,自动模式由桌宠背后的背景采样实时刷新。
    static var currentPetColor: NSColor = Settings.petColor
    static var orange: NSColor { currentPetColor }
    /// 张嘴时口腔暗色,压在橙色花瓣上凸显“嘴”
    static let mouth = NSColor(srgbRed: 0x5A / 255.0, green: 0x2A / 255.0, blue: 0x1C / 255.0, alpha: 1.0)
    /// 呼吸完整周期(秒):一次缩放的吸→呼
    static let breathPeriod: Double = 6
    /// 眼睛方向刷新周期(秒):只重绘 90pt 小图,20fps 足够顺滑且开销可控
    static let eyeFollowPeriod: TimeInterval = 1.0 / 20.0
    /// 环境颜色刷新周期(秒):不截图,只根据系统外观/强调色/前台 App 变化调色
    static let ambientColorUpdatePeriod: TimeInterval = 1.2
    /// 微信未读提示轮询周期(秒):只做轻量辅助功能树查询,不读取聊天数据库或消息正文
    static let weChatNotificationCheckPeriod: TimeInterval = 2.0
    /// 窗口边长(点)
    static let windowSize: CGFloat = 90
    /// 通知横幅尺寸:窗口额外留出顶部透明区域,平时不显示文字(微信未读 / Claude·Codex 任务完成共用)。
    /// 高度自适应:短文案=单行(bannerMinHeight),长任务简介自动换行加高,上限 bannerMaxHeight。
    static let bannerWidth: CGFloat = 210
    static let bannerMinHeight: CGFloat = 34
    static let bannerMaxHeight: CGFloat = 116
    static let bannerGap: CGFloat = 6
    static var canvasSize: CGSize {
        CGSize(width: bannerWidth, height: windowSize + bannerGap + bannerMaxHeight)
    }
}

// MARK: - 用户设置
// 访问级别为 internal(模块内可见):远程遥控模块 RemoteControl.swift 直接读写这里的开关与 token,
// 故不能用 private/fileprivate。键名与读取助手仍各自 private,只对外暴露语义化的开关属性。
enum Settings {
    private static let pounceDurationKey = "pounceDuration"
    private static let petColorKey = "petColor"
    private static let autoAdaptColorKey = "autoAdaptColor"
    private static let receiveWeChatNotificationsKey = "receiveWeChatNotifications"
    static let defaultPounceDuration: Double = 0.85
    static let minPounceDuration: Double = 0.35
    static let maxPounceDuration: Double = 8.0
    static let defaultPetColor = NSColor(srgbRed: 0xD9 / 255.0, green: 0x77 / 255.0, blue: 0x57 / 255.0, alpha: 1.0)
    static let defaultAutoAdaptColor = true
    static let defaultReceiveWeChatNotifications = false

    static var pounceDuration: Double {
        get {
            let value = UserDefaults.standard.double(forKey: pounceDurationKey)
            guard value > 0 else { return defaultPounceDuration }
            return min(max(value, minPounceDuration), maxPounceDuration)
        }
        set {
            let value = min(max(newValue, minPounceDuration), maxPounceDuration)
            UserDefaults.standard.set(value, forKey: pounceDurationKey)
        }
    }

    static var petColor: NSColor {
        get {
            guard let data = UserDefaults.standard.data(forKey: petColorKey),
                  let color = try? NSKeyedUnarchiver.unarchivedObject(ofClass: NSColor.self, from: data) else {
                return defaultPetColor
            }
            return color.usingColorSpace(.sRGB) ?? defaultPetColor
        }
        set {
            guard let data = try? NSKeyedArchiver.archivedData(withRootObject: newValue, requiringSecureCoding: true) else { return }
            UserDefaults.standard.set(data, forKey: petColorKey)
        }
    }

    static var autoAdaptColor: Bool {
        get {
            guard UserDefaults.standard.object(forKey: autoAdaptColorKey) != nil else {
                return defaultAutoAdaptColor
            }
            return UserDefaults.standard.bool(forKey: autoAdaptColorKey)
        }
        set {
            UserDefaults.standard.set(newValue, forKey: autoAdaptColorKey)
        }
    }

    static var receiveWeChatNotifications: Bool {
        get {
            guard UserDefaults.standard.object(forKey: receiveWeChatNotificationsKey) != nil else {
                return defaultReceiveWeChatNotifications
            }
            return UserDefaults.standard.bool(forKey: receiveWeChatNotificationsKey)
        }
        set {
            UserDefaults.standard.set(newValue, forKey: receiveWeChatNotificationsKey)
        }
    }

    /// 任务完成提示开关(Claude/Codex 报喜),缺省开启——这是主动配了 hook 才会用到的功能。
    private static let receiveTaskDoneNotificationsKey = "receiveTaskDoneNotifications"
    static var receiveTaskDoneNotifications: Bool {
        get {
            guard UserDefaults.standard.object(forKey: receiveTaskDoneNotificationsKey) != nil else { return true }
            return UserDefaults.standard.bool(forKey: receiveTaskDoneNotificationsKey)
        }
        set { UserDefaults.standard.set(newValue, forKey: receiveTaskDoneNotificationsKey) }
    }

    // MARK: 陪跑 / 作息 / 窗口 —— 新增设置(各自缺省值见注释)
    private static let petFocusOnStartKey = "petFocusOnStart"
    private static let petNotifyOnWaitingKey = "petNotifyOnWaiting"
    private static let petMoodDecayKey = "petMoodDecay"
    private static let petSedentaryReminderKey = "petSedentaryReminder"
    private static let petSedentaryMinutesKey = "petSedentaryMinutes"
    private static let petNightDrowsyKey = "petNightDrowsy"
    private static let petDockCornerKey = "petDockCorner"
    private static let petTranslateKey = "petTranslate"
    private static let petDoNotDisturbKey = "petDoNotDisturb"
    private static let petShowSessionBadgeKey = "petShowSessionBadge"
    static let defaultSedentaryMinutes = 50
    static let minSedentaryMinutes = 10
    static let maxSedentaryMinutes = 180

    /// 带默认值的 UserDefaults 读取:未写入过时返回 def,避免 bool/integer 把"没设过"误读成 false/0。
    private static func stringValue(_ key: String, default def: String) -> String { UserDefaults.standard.string(forKey: key) ?? def }
    private static func boolValue(_ key: String, default def: Bool) -> Bool {
        UserDefaults.standard.object(forKey: key) == nil ? def : UserDefaults.standard.bool(forKey: key)
    }
    private static func intValue(_ key: String, default def: Int) -> Int {
        UserDefaults.standard.object(forKey: key) == nil ? def : UserDefaults.standard.integer(forKey: key)
    }

    /// 陪跑:开工进专注态,缺省开
    static var petFocusOnStart: Bool {
        get { boolValue(petFocusOnStartKey, default: true) }
        set { UserDefaults.standard.set(newValue, forKey: petFocusOnStartKey) }
    }
    /// 陪跑:等确认时提醒,缺省开
    static var petNotifyOnWaiting: Bool {
        get { boolValue(petNotifyOnWaitingKey, default: true) }
        set { UserDefaults.standard.set(newValue, forKey: petNotifyOnWaitingKey) }
    }
    /// 作息:会饿会蔫,缺省开
    static var petMoodDecay: Bool {
        get { boolValue(petMoodDecayKey, default: true) }
        set { UserDefaults.standard.set(newValue, forKey: petMoodDecayKey) }
    }
    /// 作息:久坐提醒,缺省关
    static var petSedentaryReminder: Bool {
        get { boolValue(petSedentaryReminderKey, default: false) }
        set { UserDefaults.standard.set(newValue, forKey: petSedentaryReminderKey) }
    }
    /// 作息:久坐提醒间隔(分钟),默认 50,夹在 10~180
    static var petSedentaryMinutes: Int {
        get { min(max(intValue(petSedentaryMinutesKey, default: defaultSedentaryMinutes), minSedentaryMinutes), maxSedentaryMinutes) }
        set { UserDefaults.standard.set(min(max(newValue, minSedentaryMinutes), maxSedentaryMinutes), forKey: petSedentaryMinutesKey) }
    }
    /// 作息:深夜犯困,缺省开
    static var petNightDrowsy: Bool {
        get { boolValue(petNightDrowsyKey, default: true) }
        set { UserDefaults.standard.set(newValue, forKey: petNightDrowsyKey) }
    }
    /// 窗口:停靠角(见 DockCorner.rawValue,0=左上 1=右上 2=左下 3=右下),默认右下
    static var petDockCorner: Int {
        get { intValue(petDockCornerKey, default: 3) }
        set { UserDefaults.standard.set(newValue, forKey: petDockCornerKey) }
    }
    /// 划词翻译:选中文字按 ⌥⌘T 翻成中/英,缺省开
    static var petTranslate: Bool {
        get { boolValue(petTranslateKey, default: true) }
        set { UserDefaults.standard.set(newValue, forKey: petTranslateKey) }
    }
    /// 通知:免打扰——静音一切被动提示(微信/飞书/等确认/收工/久坐),缺省关。主公主动触发的(翻译/测试)不受其约束。
    static var petDoNotDisturb: Bool {
        get { boolValue(petDoNotDisturbKey, default: false) }
        set { UserDefaults.standard.set(newValue, forKey: petDoNotDisturbKey) }
    }
    /// 陪跑:显示并发会话角标(绿点跑·琥珀点等)与等确认持续催促,缺省开
    static var petShowSessionBadge: Bool {
        get { boolValue(petShowSessionBadgeKey, default: true) }
        set { UserDefaults.standard.set(newValue, forKey: petShowSessionBadgeKey) }
    }

    // MARK: 远程遥控(Telegram)
    // 经 Telegram Bot 把消息当 prompt 喂给 cc/cx、回话回传;cc/cx 各占一个独立 bot。
    // token/chat id 属本机隐私,只落 UserDefaults,绝不写进代码或随仓库提交。
    private static let remoteEnabledKey = "remoteEnabled"
    private static let telegramClaudeTokenKey = "telegramClaudeToken"
    private static let telegramCodexTokenKey = "telegramCodexToken"
    private static let telegramAllowedChatIDsKey = "telegramAllowedChatIDs"

    /// 远程遥控总开关,缺省关——没填 token 前不空轮询。
    static var remoteEnabled: Bool {
        get { boolValue(remoteEnabledKey, default: false) }
        set { UserDefaults.standard.set(newValue, forKey: remoteEnabledKey) }
    }
    /// cc(Claude)对应 bot 的 token,空串表示未配置。
    static var telegramClaudeToken: String {
        get { stringValue(telegramClaudeTokenKey, default: "").trimmingCharacters(in: .whitespacesAndNewlines) }
        set { UserDefaults.standard.set(newValue, forKey: telegramClaudeTokenKey) }
    }
    /// cx(Codex)对应 bot 的 token,空串表示未配置。
    static var telegramCodexToken: String {
        get { stringValue(telegramCodexTokenKey, default: "").trimmingCharacters(in: .whitespacesAndNewlines) }
        set { UserDefaults.standard.set(newValue, forKey: telegramCodexTokenKey) }
    }
    /// 允许下发指令的 chat id 白名单(逗号/空白分隔)。非空时只认名单内的 chat,挡掉陌生人。
    static var telegramAllowedChatIDs: String {
        get { stringValue(telegramAllowedChatIDsKey, default: "") }
        set { UserDefaults.standard.set(newValue, forKey: telegramAllowedChatIDsKey) }
    }
    /// 把白名单字符串切成去空的 id 集合;空集合表示"未设白名单"(此时全部放行,日志会提示)。
    static var telegramAllowedChatIDSet: Set<String> {
        Set(telegramAllowedChatIDs
            .split(whereSeparator: { $0 == "," || $0 == " " || $0 == "\n" || $0 == "\t" })
            .map(String.init)
            .filter { !$0.isEmpty })
    }

    // MARK: 远程遥控(飞书 Feishu)
    // 经飞书长连接把消息当 prompt 喂给 cc/cx;cc/cx 各对应一个企业自建应用。与 Telegram 共用 remoteEnabled 总开关。
    // app_id/app_secret 属本机隐私,只落 UserDefaults,绝不写进代码或随仓库提交。
    private static let feishuClaudeAppIDKey = "feishuClaudeAppID"
    private static let feishuClaudeAppSecretKey = "feishuClaudeAppSecret"
    private static let feishuCodexAppIDKey = "feishuCodexAppID"
    private static let feishuCodexAppSecretKey = "feishuCodexAppSecret"
    private static let feishuAllowedOpenIDsKey = "feishuAllowedOpenIDs"

    /// cc(Claude)对应飞书应用的 app_id,空串表示未配置。
    static var feishuClaudeAppID: String {
        get { stringValue(feishuClaudeAppIDKey, default: "").trimmingCharacters(in: .whitespacesAndNewlines) }
        set { UserDefaults.standard.set(newValue, forKey: feishuClaudeAppIDKey) }
    }
    static var feishuClaudeAppSecret: String {
        get { stringValue(feishuClaudeAppSecretKey, default: "").trimmingCharacters(in: .whitespacesAndNewlines) }
        set { UserDefaults.standard.set(newValue, forKey: feishuClaudeAppSecretKey) }
    }
    /// cx(Codex)对应飞书应用的 app_id,空串表示未配置。
    static var feishuCodexAppID: String {
        get { stringValue(feishuCodexAppIDKey, default: "").trimmingCharacters(in: .whitespacesAndNewlines) }
        set { UserDefaults.standard.set(newValue, forKey: feishuCodexAppIDKey) }
    }
    static var feishuCodexAppSecret: String {
        get { stringValue(feishuCodexAppSecretKey, default: "").trimmingCharacters(in: .whitespacesAndNewlines) }
        set { UserDefaults.standard.set(newValue, forKey: feishuCodexAppSecretKey) }
    }
    /// 允许下发指令的发送者 open_id 白名单(逗号/空白分隔)。非空时只认名单内的人,挡掉陌生人。
    static var feishuAllowedOpenIDs: String {
        get { stringValue(feishuAllowedOpenIDsKey, default: "") }
        set { UserDefaults.standard.set(newValue, forKey: feishuAllowedOpenIDsKey) }
    }
    static var feishuAllowedOpenIDSet: Set<String> {
        Set(feishuAllowedOpenIDs
            .split(whereSeparator: { $0 == "," || $0 == " " || $0 == "\n" || $0 == "\t" })
            .map(String.init)
            .filter { !$0.isEmpty })
    }

    /// 泛化的 IM 通知开关读写(微信/飞书共用),按 UserDefaults 键存取,缺省关闭。
    static func imNotificationsEnabled(_ key: String) -> Bool {
        UserDefaults.standard.object(forKey: key) == nil ? false : UserDefaults.standard.bool(forKey: key)
    }

    static func setIMNotificationsEnabled(_ key: String, _ on: Bool) {
        UserDefaults.standard.set(on, forKey: key)
    }

    // MARK: 任务监控 —— 把远程遥控每轮"问题→答案"落盘并起本地仪表盘服务(默认关闭)
    private static let monitorEnabledKey = "monitorEnabled"
    private static let monitorPortKey = "monitorPort"
    private static let monitorPluginPathKey = "monitorPluginPath"
    static let defaultMonitorPort = 8722

    /// 挂载监控系统总开关:开则记录任务并起内嵌 HTTP 服务,关则停服务、停记录。
    static var monitorEnabled: Bool {
        get { boolValue(monitorEnabledKey, default: false) }
        set { UserDefaults.standard.set(newValue, forKey: monitorEnabledKey) }
    }

    /// 仪表盘服务端口(浏览器访问 http://127.0.0.1:端口),缺省 8722,限定 1024–65535。
    static var monitorPort: Int {
        get { let p = intValue(monitorPortKey, default: defaultMonitorPort); return (p >= 1024 && p <= 65535) ? p : defaultMonitorPort }
        set { UserDefaults.standard.set(min(max(newValue, 1024), 65535), forKey: monitorPortKey) }
    }

    /// 前端 dist 目录覆盖路径;留空则自动定位兄弟项目 claude-pet-monitor/dist,再缺则走内置回退页。
    static var monitorPluginPath: String {
        get { stringValue(monitorPluginPathKey, default: "").trimmingCharacters(in: .whitespacesAndNewlines) }
        set { UserDefaults.standard.set(newValue, forKey: monitorPluginPathKey) }
    }
}

/// 桌宠停靠屏幕四角之一(rawValue 存入 UserDefaults 的 petDockCorner)
private enum DockCorner: Int, CaseIterable {
    case topLeft = 0, topRight = 1, bottomLeft = 2, bottomRight = 3
    var title: String {
        switch self {
        case .topLeft: return "左上角"
        case .topRight: return "右上角"
        case .bottomLeft: return "左下角"
        case .bottomRight: return "右下角"
        }
    }
    /// 据屏幕可见区与窗口尺寸算停靠原点(留边距;右下与原逻辑一致:maxX-宽-40, minY+40)
    func origin(in visible: NSRect, size: CGSize, margin: CGFloat = 40) -> NSPoint {
        let onLeft = (self == .topLeft || self == .bottomLeft)
        let onTop = (self == .topLeft || self == .topRight)
        return NSPoint(x: onLeft ? visible.minX + margin : visible.maxX - size.width - margin,
                       y: onTop ? visible.maxY - size.height - margin : visible.minY + margin)
    }
    static var current: DockCorner { DockCorner(rawValue: Settings.petDockCorner) ?? .bottomRight }
}

private extension Notification.Name {
    static let petColorDidChange = Notification.Name("ClaudePet.petColorDidChange")
    static let autoAdaptColorDidChange = Notification.Name("ClaudePet.autoAdaptColorDidChange")
    static let weChatNotificationsDidChange = Notification.Name("ClaudePet.weChatNotificationsDidChange")
    static let dockCornerDidChange = Notification.Name("ClaudePet.dockCornerDidChange")
    static let petBehaviorDidChange = Notification.Name("ClaudePet.petBehaviorDidChange")
}

private extension NSColor {
    var hexSignature: String {
        let color = usingColorSpace(.sRGB) ?? self
        let red = Int(round(color.redComponent * 255))
        let green = Int(round(color.greenComponent * 255))
        let blue = Int(round(color.blueComponent * 255))
        return String(format: "%02X%02X%02X", red, green, blue)
    }
}

// MARK: - 宠物视图
// 按终端象限网格自绘 Claude 星芒(还原 Claude Code 欢迎界面的方块星芒),
// 交给 Core Animation 做安静的“呼吸”缩放;draw(_:) 仅供离屏快照,运行时由图层显示。
final class PetView: NSView {
    /// 离屏快照底色档:深色档模拟深桌面、浅色档模拟亮桌面,用于核对描边轮廓在两种背景下的可见性
    static let snapshotDarkBackground = NSColor(srgbRed: 0x1E / 255.0, green: 0x1E / 255.0, blue: 0x1E / 255.0, alpha: 1)
    static let snapshotLightBackground = NSColor(srgbRed: 0xEC / 255.0, green: 0xEC / 255.0, blue: 0xEC / 255.0, alpha: 1)
    /// 离屏快照模式:为透明背景铺底色,便于肉眼/AI 核对渲染效果
    private var snapshotBackground = false
    /// 离屏快照所铺底色,默认深色档;--render-test 可切浅色档核对描边在亮背景上的勾边
    private var snapshotBgColor = PetView.snapshotDarkBackground
    /// 离屏快照时的张嘴幅度(0=闭嘴),便于自测渲染“吃”的一帧
    private var snapshotMouthOpen: CGFloat = 0
    /// 离屏快照时的眼睛偏移方向,复用原图两个深色空位做眼睛
    private var snapshotEyeLook = CGVector(dx: 0, dy: 0)
    /// 离屏快照时的眼形(睁/闭/弯月笑),核对眨眼与眯眼笑的渲染
    private var snapshotEyeMode: EyeMode = .normal
    /// 离屏快照时的跑步腿相位,用于核对两腿交替摆动
    private var snapshotRunPhase = 0
    /// 承载星星图标并接受呼吸动画的图层
    private let iconLayer = CALayer()
    /// 通知横幅:比跳一下更明确,平时完全透明(微信未读 / 任务完成共用)
    private let bannerLayer = CALayer()
    private let bannerTextLayer = CATextLayer()
    /// 单一外观状态:嘴张幅(0~1)、眼神偏移、眼形(睁/闭/弯月笑)。任何动作改这几个值后调 render() 即刻重绘。
    /// 不再预渲染多帧——表情维度一多,组合会爆炸;统一一处出图反而更省、更清晰。
    private var mouthOpen: CGFloat = 0
    private var eyeLook = CGVector(dx: 0, dy: 0)
    private var eyeMode: EyeMode = .normal
    private var runPhase = 0
    /// 咀嚼定时器(.common 模式,确保拖放进行中仍触发)
    private var chewTimer: Timer?
    /// 快捷键投喂的"一口"收尾计时:拖放靠松手/离开收尾,快捷键没有拖放过程,故定时自动闭嘴
    private var biteTimer: Timer?
    /// 眼睛跟随鼠标方向的刷新定时器
    private var eyeTimer: Timer?
    /// 扑食滑行期间的跑步腿切帧定时器
    private var runTimer: Timer?
    /// 空闲动作调度定时器:久无操作时偶发眨眼/哈欠/摇晃/东张西望
    private var idleTimer: Timer?
    /// 自动适应环境色的低频刷新定时器:不走屏幕捕捉,无屏幕录制权限要求
    private var ambientColorTimer: Timer?
    private var lastAmbientColorSignature = ""
    /// IM 未读检测定时器(微信/飞书共用):只读 Dock 角标,不碰聊天数据库或正文
    private var weChatNotificationTimer: Timer?
    /// 各 IM 上一次检测到的未读数(键=IMTarget.key);无条目=上次无未读,只在“无→有”或数量变多时提示
    private var imLastUnread: [String: Int] = [:]
    /// 通知提示收尾定时器(发光/笑眼复位),微信未读与任务完成共用
    private var noticeHintTimer: Timer?
    private var bannerHideTimer: Timer?
    private var weChatAccessibilityFailureLogged = false
    private var lastWeChatPermissionHintAt = Date.distantPast
    /// 眼睛被空闲动作(眨眼/东张西望)临时接管:置位时 eyeFollow 让路,不把眼神拉回鼠标
    private var idleEyeActive = false
    /// 鼠标悬停中:悬停期间换放大版呼吸 + 眯眼笑 + 发光,并暂停空闲打扰
    private var isHovering = false
    /// 扑食动作进行中标志:防连按时把"归位坐标"记成动画途中的中间值
    private var isPouncing = false
    /// 陪跑活跃会话:sid → 会话状态(在跑/在等)。非空即"在场",多终端并发按 sid 聚合。
    /// 生命周期:start→在跑,waiting→在已有会话上转"等你"(驱动角标"等N"),done→移除会话,超时兜底清理。
    private var activeSessions: [String: SessionInfo] = [:]
    /// 单个陪跑会话状态:最近事件时间(供超时兜底)、是否在等主公(waiting 置位,驱动角标"等N")、承载会话的进程 pid(供 kill -0 探活)。
    struct SessionInfo { var at: Date; var waiting: Bool; var pid: pid_t? = nil }
    /// 每个 sid 已处理事件的最新"生成时间戳"(epoch 秒,由 hook 注入 ts 参数)。
    /// hook 每个事件都是 `open claudepet://` 一发即走,LaunchServices 不保证按发出顺序投递;sid 又在整段对话里复用——
    /// 上一轮迟到的 done 会误删刚开跑的新轮(「跑」丢)、上一轮迟到的尾随 waiting 会把新轮误标「等」(「等」错)。
    /// 据此按 ts 定序:同一 sid 收到比已处理更旧的事件一律丢弃,一并治住「跑」「等」两类错标,无需任何时间宽限窗猜测。
    private var lastEventAt: [String: Double] = [:]
    /// 并发会话角标(绿点跑·琥珀点等):内容是现画的小图,挂 view.layer、不随星芒跳动;受 petShowSessionBadge 开关。
    private let badgeLayer = CALayer()
    /// 当前横幅可"点回现场"的目录:任务完成/等确认横幅带 cwd 才置位,微信/飞书/久坐为 nil(点了不跳转)。
    private var bannerActionCwd: String?
    /// 当前横幅对应会话的终端 tty(形如 /dev/ttys003):由陪跑 URL 携带,点横幅时据此精确回到这一个终端窗口;
    /// 多终端并发时光靠 cwd 区分不出(常都在同一仓库目录),tty 才能定位到具体那一摊。空则退回整 App 唤前台。
    private var bannerActionTty: String?
    /// 活跃会话超时清理:某终端崩了没发 done 会赖在集合里,定时踢出陈旧会话,免得永远卡专注。
    private var sessionSweepTimer: Timer?
    /// 是否有会话正在跑(不含"在等你"的)——驱动专注呼吸;在等待/全空时回常态。
    private var isWorking: Bool { activeSessions.contains { !$0.value.waiting } }
    /// 上次被搭理(摸/喂/嚼)的时刻;久无互动会"蔫"。
    private var lastInteractionAt = Date()
    /// 正蔫着:缩着身子、慢呼吸、垂眼;被搭理即回血。
    private var isDrooping = false
    private var moodTimer: Timer?            // 会饿会蔫的低频检查
    private var sedentaryTimer: Timer?       // 久坐提醒
    private static let moodDecaySeconds: TimeInterval = 30 * 60   // 30 分钟没人理就蔫

    private var petFrameInBounds: CGRect {
        CGRect(x: (bounds.width - Style.windowSize) / 2,
               y: 0,
               width: Style.windowSize,
               height: Style.windowSize)
    }

    /// 眼形三态:统一驱动眨眼(closed)、哈欠闭眼(closed)、眯眼笑(happy)。normal 时才随鼠标偏移。
    enum EyeMode { case normal, closed, happy }

    /// Claude 星芒的方块拼图(取自 Claude Code 欢迎界面),逐字符按象限自绘,严丝合缝
    private static let starArt = [
        " ▐▛███▜▌",
        "▝▜█████▛▘",
        "  ▘▘ ▝▝",
    ]

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        // 只让 iconLayer 这一份显示内容:禁止 AppKit 自动把 draw(_:) 画进背衬层,
        // 否则背衬层会多画一份星芒,跳/摇时 iconLayer 移开就露出"第二个身体"。
        // 离屏快照走显式 view.draw(_:) 调用,不受此策略影响。
        layerContentsRedrawPolicy = .never
        layer?.masksToBounds = false
        setupIconLayer(scale: NSScreen.main?.backingScaleFactor ?? 2)
        registerForDraggedTypes([.fileURL]) // 接住拖入的文件,投喂给 claude 分析
        NotificationCenter.default.addObserver(self, selector: #selector(handlePetColorDidChange(_:)), name: .petColorDidChange, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(handleAutoAdaptColorDidChange(_:)), name: .autoAdaptColorDidChange, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(handleWeChatNotificationsDidChange(_:)), name: .weChatNotificationsDidChange, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(handleBehaviorDidChange(_:)), name: .petBehaviorDidChange, object: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("不支持 Interface Builder 加载") }

    deinit {
        NotificationCenter.default.removeObserver(self)
        ambientColorTimer?.invalidate()
        weChatNotificationTimer?.invalidate()
        noticeHintTimer?.invalidate()
        bannerHideTimer?.invalidate()
        sessionSweepTimer?.invalidate()
        moodTimer?.invalidate()
        sedentaryTimer?.invalidate()
    }

    // MARK: 图层装配
    private func setupIconLayer(scale: CGFloat) {
        iconLayer.frame = petFrameInBounds
        iconLayer.anchorPoint = CGPoint(x: 0.5, y: 0.5) // 绕中心缩放
        iconLayer.position = CGPoint(x: iconLayer.frame.midX, y: iconLayer.frame.midY)
        iconLayer.contentsGravity = .resizeAspect // 保持图标比例
        iconLayer.contentsScale = scale
        layer?.addSublayer(iconLayer)
        setupBannerLayer(scale: scale)
        setupBadgeLayer(scale: scale)
        applyBaseShadow() // 常驻淡落地阴影,替代被关掉的窗口阴影
        render() // 画出初始常态帧
    }

    private func setupBannerLayer(scale: CGFloat) {
        bannerLayer.frame = CGRect(x: (bounds.width - Style.bannerWidth) / 2,
                                         y: Style.windowSize + Style.bannerGap,
                                         width: Style.bannerWidth,
                                         height: Style.bannerMinHeight)
        bannerLayer.cornerRadius = 8
        bannerLayer.backgroundColor = NSColor(srgbRed: 0.08, green: 0.09, blue: 0.10, alpha: 0.92).cgColor
        bannerLayer.borderWidth = 1
        bannerLayer.borderColor = Style.orange.cgColor // 默认色;每次 showBanner 按通知类型覆盖(微信绿 / 任务橙)
        bannerLayer.shadowColor = NSColor.black.cgColor
        bannerLayer.shadowRadius = 8
        bannerLayer.shadowOpacity = 0.28
        bannerLayer.shadowOffset = CGSize(width: 0, height: -2)
        bannerLayer.opacity = 0

        bannerTextLayer.frame = CGRect(x: 12, y: 7, width: Style.bannerWidth - 24, height: 20)
        bannerTextLayer.contentsScale = scale
        bannerTextLayer.alignmentMode = .center
        bannerTextLayer.isWrapped = true            // 长任务简介自动换行,配合 showBanner 测高自适应
        bannerTextLayer.truncationMode = .end
        bannerTextLayer.foregroundColor = NSColor.white.cgColor
        bannerTextLayer.font = NSFont.systemFont(ofSize: 13, weight: .semibold)
        bannerTextLayer.fontSize = 13
        bannerTextLayer.string = ""
        bannerLayer.addSublayer(bannerTextLayer)
        layer?.addSublayer(bannerLayer)
    }

    /// 会话角标图层装配:内容是 updateSessionBadge 现画的小图(状态圆点+白字数),初始隐藏。
    private func setupBadgeLayer(scale: CGFloat) {
        badgeLayer.opacity = 0
        badgeLayer.contentsScale = scale
        badgeLayer.contentsGravity = .resizeAspect
        layer?.addSublayer(badgeLayer)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard let window else { return }
        iconLayer.contentsScale = window.backingScaleFactor // 适配真实屏幕缩放,保证清晰
        bannerTextLayer.contentsScale = window.backingScaleFactor
        badgeLayer.contentsScale = window.backingScaleFactor
        render()              // 缩放确定后重绘一帧,保证清晰
        startBreathing()
        startEyeFollow()
        updateBackgroundColorSampling()
        updateWeChatNotificationMonitor()
        scheduleIdle()        // 启动空闲动作调度
        startMoodTimer()      // 启动"会饿会蔫"低频检查
        startSedentaryTimerIfNeeded()  // 久坐提醒(受开关控制)
    }

    // MARK: 呼吸动画(交给 Core Animation,无需逐帧重绘)
    // 常态在 0.95~1.0 间缓缓缩放;悬停时换成放大区间(见 onHoverBegin),呼吸不停、只是"鼓"起来。
    private func startBreathing(scaleLow: CGFloat = 0.95, scaleHigh: CGFloat = 1.0, period: Double = Style.breathPeriod) {
        let breathe = CABasicAnimation(keyPath: "transform.scale")
        breathe.fromValue = scaleLow
        breathe.toValue = scaleHigh
        breathe.duration = period / 2
        breathe.autoreverses = true
        breathe.repeatCount = .infinity
        breathe.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        iconLayer.add(breathe, forKey: "breathe") // 同 key 重加即替换,实现常态↔放大切换
    }

    /// 按当前状态选呼吸节奏:悬停最鼓、陪跑专注略鼓略快、否则常态。集中一处,避免各路调用各传参数互相覆盖。
    private func applyBreathing() {
        if isHovering {
            startBreathing(scaleLow: 1.08, scaleHigh: 1.18)               // 悬停:鼓起来
        } else if isWorking {
            startBreathing(scaleLow: 0.97, scaleHigh: 1.05, period: 3.4)  // 陪跑专注:略鼓、略快
        } else if isDrooping {
            startBreathing(scaleLow: 0.92, scaleHigh: 0.97, period: 9)    // 蔫:缩着、慢吞吞
        } else {
            startBreathing()                                              // 常态
        }
    }

    // MARK: 眼睛跟随鼠标方向
    // 不新增眼睛素材;只把原图中上部两个深色空位当眼睛,随鼠标方向在原位附近轻微挪动。
    private func startEyeFollow() {
        guard eyeTimer == nil else { return }
        updateEyeLookFromMouse()
        let timer = Timer(timeInterval: Style.eyeFollowPeriod, repeats: true) { [weak self] _ in
            self?.updateEyeLookFromMouse()
        }
        RunLoop.main.add(timer, forMode: .common)
        eyeTimer = timer
    }

    private func updateEyeLookFromMouse() {
        guard let window else {
            eyeTimer?.invalidate()
            eyeTimer = nil
            return
        }
        guard !idleEyeActive, !isHovering else { return } // 东张西望/眨眼/悬停接管眼睛时让路,不与之抢
        let center = CGPoint(x: window.frame.midX, y: window.frame.midY)
        let mouse = NSEvent.mouseLocation
        let dx = mouse.x - center.x
        let dy = mouse.y - center.y
        let distance = hypot(dx, dy)
        let nextLook: CGVector
        if distance < 8 {
            nextLook = CGVector(dx: 0, dy: 0)
        } else {
            let strength = min(distance / 140, 1)
            nextLook = CGVector(dx: dx / distance * strength, dy: dy / distance * strength)
        }
        guard abs(nextLook.dx - eyeLook.dx) > 0.02 || abs(nextLook.dy - eyeLook.dy) > 0.02 else { return }
        eyeLook = nextLook
        render()
    }

    /// 按当前外观状态(嘴/眼神/眼形)出一帧并送入图层。所有动作改完状态后都走这里,单一出图口径。
    private func render() {
        let image = Self.starImage(size: iconLayer.bounds.size, mouthOpen: mouthOpen, eyeLook: eyeLook, eyeMode: eyeMode, runPhase: runPhase)
        setFrame(image.cgImage(forProposedRect: nil, context: nil, hints: nil))
    }

    @objc private func handlePetColorDidChange(_ notification: Notification) {
        if !Settings.autoAdaptColor {
            Style.currentPetColor = Settings.petColor
        }
        render()
        setFeedGlow(isHovering || chewTimer != nil)
    }

    @objc private func handleAutoAdaptColorDidChange(_ notification: Notification) {
        updateBackgroundColorSampling()
    }

    @objc private func handleWeChatNotificationsDidChange(_ notification: Notification) {
        updateWeChatNotificationMonitor()
    }

    // MARK: 环境色自动适应
    // 不做屏幕捕捉;稳定跟随系统深浅模式与强调色生成鲜艳醒目的主色,可见性由描边轮廓兜底。
    // 这不是桌宠背后像素的真实颜色,但无需屏幕录制权限,也不会触碰屏幕内容。
    private func updateBackgroundColorSampling() {
        if Settings.autoAdaptColor {
            startAmbientColorAdaptation()
        } else {
            stopAmbientColorAdaptation(resetToManualColor: true)
        }
    }

    private func startAmbientColorAdaptation() {
        guard ambientColorTimer == nil else {
            updateAmbientColorAndApply()
            return
        }
        updateAmbientColorAndApply()
        let timer = Timer(timeInterval: Style.ambientColorUpdatePeriod, repeats: true) { [weak self] _ in
            self?.updateAmbientColorAndApply()
        }
        RunLoop.main.add(timer, forMode: .common)
        ambientColorTimer = timer
    }

    private func stopAmbientColorAdaptation(resetToManualColor: Bool) {
        ambientColorTimer?.invalidate()
        ambientColorTimer = nil
        lastAmbientColorSignature = ""
        guard resetToManualColor else { return }
        Style.currentPetColor = Settings.petColor
        render()
        setFeedGlow(isHovering || chewTimer != nil)
    }

    private func updateAmbientColorAndApply() {
        guard Settings.autoAdaptColor else { return }
        let environment = Self.currentColorEnvironment()
        guard environment.signature != lastAmbientColorSignature else { return }
        lastAmbientColorSignature = environment.signature
        let nextColor = Self.adaptivePetColor(for: environment, manualColor: Settings.petColor)
        guard Self.colorDistance(nextColor, Style.currentPetColor) > 0.04 else { return }
        Style.currentPetColor = nextColor
        render()
        setFeedGlow(isHovering || chewTimer != nil)
    }

    private struct ColorEnvironment {
        let accentColor: NSColor
        let isDarkAppearance: Bool
        let signature: String
    }

    private static func currentColorEnvironment() -> ColorEnvironment {
        let appearance = NSApp.effectiveAppearance
        let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let accent = NSColor.controlAccentColor.usingColorSpace(.sRGB) ?? Settings.defaultPetColor
        return ColorEnvironment(
            accentColor: accent,
            isDarkAppearance: isDark,
            signature: "\(isDark)|\(accent.hexSignature)"
        )
    }

    /// 自动主色:稳定跟随系统强调色的色相,始终保持鲜艳偏亮,只随系统深浅做轻微微调。
    /// 不再掺前台 App 名字的随机 hash(那只会让颜色乱跳)、也不再用浅色模式 0.43 的发暗值——
    /// 真正"看清"靠描边轮廓兜底,这里只负责给一个好看且不撞背景的醒目色。
    private static func adaptivePetColor(for environment: ColorEnvironment, manualColor: NSColor) -> NSColor {
        let accent = environment.accentColor.usingColorSpace(.sRGB) ?? environment.accentColor
        let manual = manualColor.usingColorSpace(.sRGB) ?? defaultManualColor()
        var accentHue: CGFloat = 0, accentSaturation: CGFloat = 0, accentBrightness: CGFloat = 0
        var manualHue: CGFloat = 0, manualSaturation: CGFloat = 0, manualBrightness: CGFloat = 0
        accent.getHue(&accentHue, saturation: &accentSaturation, brightness: &accentBrightness, alpha: nil)
        manual.getHue(&manualHue, saturation: &manualSaturation, brightness: &manualBrightness, alpha: nil)

        // 色相:系统强调色够鲜艳就跟随它,否则回退手动色(赤陶橙)色相,稳定不随机
        let hue = accentSaturation > 0.12 ? accentHue : manualHue
        // 饱和度:取够高的值并抬一档,保证鲜艳醒目
        let saturation = max(0.72, min(0.95, max(accentSaturation, manualSaturation) + 0.12))
        // 明度:始终偏亮醒目,只随系统深浅轻微微调,不再在浅色模式下发暗
        let brightness: CGFloat = environment.isDarkAppearance ? 0.92 : 0.82
        return NSColor(hue: hue,
                       saturation: saturation,
                       brightness: brightness,
                       alpha: 1).usingColorSpace(.sRGB) ?? manual
    }

    private static func colorDistance(_ lhs: NSColor, _ rhs: NSColor) -> CGFloat {
        let a = lhs.usingColorSpace(.sRGB) ?? lhs
        let b = rhs.usingColorSpace(.sRGB) ?? rhs
        let dr = a.redComponent - b.redComponent
        let dg = a.greenComponent - b.greenComponent
        let db = a.blueComponent - b.blueComponent
        return sqrt(dr * dr + dg * dg + db * db)
    }

    private static func defaultManualColor() -> NSColor {
        Settings.defaultPetColor
    }

    // MARK: 微信新消息提示
    // 只通过辅助功能读取微信或 Dock 的未读提示文本,不读取微信数据库、不解密、不保存聊天内容。
    private func updateWeChatNotificationMonitor() {
        // 任一 IM(微信/飞书)开启就启动轮询,全部关闭才停。
        if Self.imTargets.contains(where: { Settings.imNotificationsEnabled($0.settingsKey) }) {
            startWeChatNotificationMonitor()
        } else {
            stopWeChatNotificationMonitor()
        }
    }

    private func startWeChatNotificationMonitor() {
        guard weChatNotificationTimer == nil else {
            checkWeChatUnreadAndHint()
            return
        }
        _ = Self.accessibilityTrusted(prompt: true)
        checkWeChatUnreadAndHint()
        let timer = Timer(timeInterval: Style.weChatNotificationCheckPeriod, repeats: true) { [weak self] _ in
            self?.checkWeChatUnreadAndHint()
        }
        RunLoop.main.add(timer, forMode: .common)
        weChatNotificationTimer = timer
    }

    private func stopWeChatNotificationMonitor() {
        weChatNotificationTimer?.invalidate()
        weChatNotificationTimer = nil
        noticeHintTimer?.invalidate()
        noticeHintTimer = nil
        bannerHideTimer?.invalidate()
        bannerHideTimer = nil
        imLastUnread.removeAll()
        if chewTimer == nil, !isHovering {
            setFeedGlow(false)
        }
    }

    private func checkWeChatUnreadAndHint() {
        let enabled = Self.imTargets.filter { Settings.imNotificationsEnabled($0.settingsKey) }
        guard !enabled.isEmpty else { return }
        guard Self.accessibilityTrusted(prompt: false) else {
            if Date().timeIntervalSince(lastWeChatPermissionHintAt) > 10 {
                lastWeChatPermissionHintAt = Date()
                showWeChatNotificationHint(message: "请开启辅助功能", duration: 8.0)
            }
            logWeChatAccessibilityFailure("接收 IM 通知需要在系统设置里允许 ClaudePet 使用辅助功能")
            return
        }
        weChatAccessibilityFailureLogged = false
        // 逐个 IM 读 Dock 角标:只在"无未读→有未读"或"未读数变多(来了新消息)"时提示;
        // 读消息导致角标变少或清零绝不提示,避免已读后仍被打扰。
        for target in enabled {
            guard let count = Self.dockBadgeCount(titleKeywords: target.dockTitleKeywords) else {
                imLastUnread[target.key] = nil   // 角标消失=已读清零,复位以便下次"无→有"边沿
                continue
            }
            let becameUnread = imLastUnread[target.key] == nil
            let countIncreased = count > (imLastUnread[target.key] ?? 0)
            imLastUnread[target.key] = count
            if becameUnread || countIncreased {
                Self.log("\(target.displayName)新消息提示 count=\(count)")
                flashNotice("\(target.displayName)来消息了 \(count) 条", accent: target.accent, duration: 6.0)
            }
        }
    }

    /// 微信未读提示用的强调色(绿色边框),与任务完成的橙色区分。
    private static let weChatAccent = NSColor(srgbRed: 0.19, green: 0.80, blue: 0.40, alpha: 0.95)
    /// 飞书未读提示用的强调色(蓝色边框),与微信绿、任务橙区分。
    private static let larkAccent = NSColor(srgbRed: 0.20, green: 0.44, blue: 1.0, alpha: 0.95)

    /// 受监控的即时通讯应用。微信、飞书各自独立开关与未读状态,共用同一套 Dock 角标探测与提示逻辑。
    /// 未读数都挂在 Dock 图标的 AXStatusLabel 角标上,清零即消失,是最干净、随已读实时变化的信号。
    private struct IMTarget {
        let key: String                  // 区分各 IM 的未读状态与设置项
        let displayName: String          // 横幅文案用:"微信" / "飞书"
        let dockTitleKeywords: [String]  // 匹配 Dock 图标 title(小写包含即命中)
        let settingsKey: String          // UserDefaults 开关键
        let accent: NSColor              // 横幅强调色
    }

    private static let imTargets: [IMTarget] = [
        IMTarget(key: "wechat", displayName: "微信", dockTitleKeywords: ["微信", "wechat"],
                 settingsKey: "receiveWeChatNotifications", accent: weChatAccent),
        IMTarget(key: "lark", displayName: "飞书", dockTitleKeywords: ["飞书", "lark"],
                 settingsKey: "receiveLarkNotifications", accent: larkAccent),
    ]

    /// 微信未读提示:绿色横幅 + 通用庆祝动作。
    private func showWeChatNotificationHint(message: String, duration: TimeInterval = 6.0, force: Bool = false) {
        flashNotice(message, accent: Self.weChatAccent, duration: duration, force: force)
    }

    /// Claude Code / Codex 任务完成报喜:橙色(主色)横幅 + 同一套庆祝动作。actionCwd 非空时横幅可点回现场。
    func showTaskDoneHint(message: String, duration: TimeInterval = 6.0, actionCwd: String? = nil, actionTty: String? = nil, force: Bool = false) {
        flashNotice(message, accent: Style.orange, duration: duration, actionCwd: actionCwd, actionTty: actionTty, force: force)
    }

    /// 远程遥控(Telegram)活动横幅:远程收到指令(start)闪绿"开跑",答完一轮(done)闪橙带摘要,
    /// 让主公一眼看见 Mac 外有人在遥控。走被动提示通道——免打扰开启时静音。由 RemoteControl 回调在主线程调。
    /// phase 仅认 "start" / "done";summary 为答复首行摘要(done 时给,可空)。
    func remoteActivity(tool: FeedTool, phase: String, summary: String?) {
        switch phase {
        case "start":
            flashNotice("\(tool.label) 远程收到指令,开跑…", accent: Self.runningAccent)
        case "done":
            let tail = (summary?.isEmpty == false) ? ":\(summary!)" : ""
            flashNotice("\(tool.label) 远程答完一轮\(tail)", accent: Style.orange)
        default:
            break
        }
    }

    /// 主动信息横幅(force 绕过免打扰):首次把 cc/cx 写进 ~/.zshrc 后告知主公;复用统一横幅出口。
    func flashInfo(_ message: String) {
        flashNotice(message, accent: Style.orange, force: true)
    }

    /// 通用通知观感:顶部弹横幅(accent 决定边框色)+ 发光 + 跳 + 摇 + 眯眼笑,定时复位。
    /// 微信未读与任务完成共用,只是文案与强调色不同——避免两套重复的提示逻辑。
    /// actionCwd:横幅可点回现场的目录(nil 则纯展示);actionTty:精确回窗口用的终端设备;force:主公主动触发(翻译/测试),绕过免打扰。
    private func flashNotice(_ message: String, accent: NSColor, duration: TimeInterval = 6.0, actionCwd: String? = nil, actionTty: String? = nil, force: Bool = false) {
        if Settings.petDoNotDisturb && !force { return }   // 免打扰:被动提示一律静音;主动触发的传 force 绕过
        showBanner(message, accent: accent, duration: duration, actionCwd: actionCwd, actionTty: actionTty)
        setFeedGlow(true)
        jump()
        sway()
        let canOwnEyes = !isHovering && !idleEyeActive && eyeMode == .normal
        if canOwnEyes {
            eyeMode = .happy
            render()
        }
        noticeHintTimer?.invalidate()
        let timer = Timer(timeInterval: 2.2, repeats: false) { [weak self] _ in
            guard let self else { return }
            if canOwnEyes {
                self.eyeMode = .normal
                self.render()
            }
            if self.chewTimer == nil, !self.isHovering {
                self.setFeedGlow(false)
            }
            self.noticeHintTimer = nil
        }
        RunLoop.main.add(timer, forMode: .common)
        noticeHintTimer = timer
    }

    private func showBanner(_ message: String, accent: NSColor, duration: TimeInterval, actionCwd: String? = nil, actionTty: String? = nil) {
        bannerActionCwd = actionCwd               // 记下"点回现场"的目录(无则 nil,mouseUp 据此判定可点与否)
        bannerActionTty = actionTty               // 记下对应终端 tty,点横幅时优先按它精确回窗口
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        // 高度自适应:按文案在固定宽度下换行所需高度撑高横幅,底边贴星芒上方向上长
        let hPad: CGFloat = 12, vPad: CGFloat = 7
        let innerW = Style.bannerWidth - hPad * 2
        let font = NSFont.systemFont(ofSize: 13, weight: .semibold)
        let maxInnerH = Style.bannerMaxHeight - vPad * 2
        let textRect = (message as NSString).boundingRect(
            with: CGSize(width: innerW, height: maxInnerH),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: [.font: font])
        let innerH = min(ceil(textRect.height), maxInnerH)
        let bannerH = max(Style.bannerMinHeight, innerH + vPad * 2)
        bannerLayer.frame = CGRect(x: (bounds.width - Style.bannerWidth) / 2,
                                   y: Style.windowSize + Style.bannerGap,
                                   width: Style.bannerWidth, height: bannerH)
        bannerTextLayer.frame = CGRect(x: hPad, y: vPad, width: innerW, height: bannerH - vPad * 2)
        bannerTextLayer.string = message
        bannerLayer.borderColor = accent.cgColor   // 边框色随通知类型(微信绿 / 任务橙)
        bannerLayer.opacity = 1
        bannerLayer.transform = CATransform3DIdentity
        CATransaction.commit()

        let rise = CABasicAnimation(keyPath: "transform.translation.y")
        rise.fromValue = -6
        rise.toValue = 0
        rise.duration = 0.18
        rise.timingFunction = CAMediaTimingFunction(name: .easeOut)
        bannerLayer.add(rise, forKey: "banner-rise")

        let pulse = CAKeyframeAnimation(keyPath: "opacity")
        pulse.values = [1, 1, 0]
        pulse.keyTimes = [0, 0.76, 1]
        pulse.duration = duration
        pulse.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        bannerLayer.add(pulse, forKey: "banner-opacity")

        bannerHideTimer?.invalidate()
        let hide = Timer(timeInterval: duration, repeats: false) { [weak self] _ in
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            self?.bannerLayer.opacity = 0
            self?.bannerLayer.transform = CATransform3DIdentity
            CATransaction.commit()
            self?.bannerActionCwd = nil           // 横幅隐去 → 不再可点回现场
            self?.bannerActionTty = nil
            self?.bannerHideTimer = nil
        }
        RunLoop.main.add(hide, forMode: .common)
        bannerHideTimer = hide
    }

    private func logWeChatAccessibilityFailure(_ message: String) {
        guard !weChatAccessibilityFailureLogged else { return }
        weChatAccessibilityFailureLogged = true
        Self.log(message)
    }

    private struct WeChatUnreadSnapshot {
        let hasUnread: Bool
        let count: Int?
        let source: String
    }

    private struct WeChatUnreadInfo {
        let count: Int?
    }

    fileprivate static func accessibilityTrusted(prompt: Bool) -> Bool {
        if prompt {
            let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
            return AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
        }
        return AXIsProcessTrusted()
    }

    /// 探测是否已授予「完全磁盘访问」:尝试打开只有 FDA 才读得到的用户 TCC.db,打不开(被系统挡或不存在)即视为未授权。
    /// 无官方查询 API,这是社区通行的间接探测;只读不写、不改任何内容。
    fileprivate static func hasFullDiskAccess() -> Bool {
        let probe = (NSHomeDirectory() as NSString)
            .appendingPathComponent("Library/Application Support/com.apple.TCC/TCC.db")
        guard let handle = FileHandle(forReadingAtPath: probe) else { return false }
        try? handle.close()
        return true
    }

    private static func detectWeChatUnread() -> WeChatUnreadSnapshot? {
        guard let count = dockBadgeCount(titleKeywords: ["微信", "wechat"]) else { return nil }
        return WeChatUnreadSnapshot(hasUnread: true, count: count, source: "Dock角标")
    }

    /// 自取 Dock 进程根,在其 AXDockItem 列表里找 title 命中关键词的图标,读 AXStatusLabel 角标数。
    private static func dockBadgeCount(titleKeywords: [String]) -> Int? {
        guard let dock = NSWorkspace.shared.runningApplications.first(where: { $0.bundleIdentifier == "com.apple.dock" }) else { return nil }
        return dockBadgeCount(in: AXUIElementCreateApplication(dock.processIdentifier), titleKeywords: titleKeywords)
    }

    /// 角标随已读/未读实时增减、清零即消失,是判定"有没有新消息"最干净的依据;用 title 关键词
    /// 限定,避免错认 App Store/系统设置等其它带角标的图标。
    private static func dockBadgeCount(in root: AXUIElement, titleKeywords: [String]) -> Int? {
        var stack: [(AXUIElement, Int)] = [(root, 0)]
        var visited = 0
        while let (element, depth) = stack.popLast(), visited < 400 {
            visited += 1
            if accessibilityText(kAXRoleAttribute as CFString, from: element) == "AXDockItem" {
                let title = (accessibilityText(kAXTitleAttribute as CFString, from: element) ?? "").lowercased()
                if titleKeywords.contains(where: { title.contains($0.lowercased()) }),
                   let label = accessibilityText("AXStatusLabel" as CFString, from: element),
                   let count = leadingPositiveInteger(in: label) {
                    return count
                }
            }
            guard depth < 4 else { continue }
            for attribute in [kAXChildrenAttribute as CFString, kAXVisibleChildrenAttribute as CFString] {
                guard let value = copyAccessibilityAttribute(attribute, from: element),
                      let children = value as? [AXUIElement] else { continue }
                for child in children.reversed() {
                    stack.append((child, depth + 1))
                }
            }
        }
        return nil
    }

    /// 解析角标文本开头的正整数:"2"→2、"99+"→99;无数字或为 0 则 nil。
    private static func leadingPositiveInteger(in text: String) -> Int? {
        var digits = ""
        for ch in text {
            if ch.isNumber { digits.append(ch) } else { break }
        }
        guard let value = Int(digits), value > 0 else { return nil }
        return value
    }

    fileprivate static func weChatDetectionStatus() -> String {
        guard Settings.receiveWeChatNotifications else {
            return "微信通知开关:关闭"
        }
        guard accessibilityTrusted(prompt: false) else {
            return "微信通知开关:开启\n辅助功能权限:未授权"
        }
        if let snapshot = detectWeChatUnread() {
            return "微信通知开关:开启\n辅助功能权限:已授权\n检测结果:有未读\n来源:\(snapshot.source)\n数量:\(snapshot.count.map(String.init) ?? "未知")"
        }
        return "微信通知开关:开启\n辅助功能权限:已授权\n检测结果:未发现未读提示"
    }

    private static func detectWeChatUnreadFromWindowList() -> WeChatUnreadSnapshot? {
        guard let info = CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID) as? [[String: Any]] else {
            return nil
        }
        var bestCount: Int?
        var hasUnread = false
        for item in info {
            let owner = item[kCGWindowOwnerName as String] as? String ?? ""
            let title = item[kCGWindowName as String] as? String ?? ""
            let joined = "\(owner) \(title)"
            let lower = joined.lowercased()
            let mentionsWeChat = lower.contains("wechat") || joined.contains("微信")
            guard mentionsWeChat else { continue }
            if let unread = unreadInfo(from: joined, requiresWeChatName: true) {
                hasUnread = true
                if let count = unread.count {
                    bestCount = max(bestCount ?? 0, count)
                }
            }
        }
        return hasUnread ? WeChatUnreadSnapshot(hasUnread: true, count: bestCount, source: "窗口标题") : nil
    }

    private static func unreadSnapshot(in root: AXUIElement, requiresWeChatName: Bool, source: String) -> WeChatUnreadSnapshot? {
        var stack: [(AXUIElement, Int)] = [(root, 0)]
        var visited = 0
        var bestCount: Int?
        var hasUnread = false
        let textAttributes: [CFString] = [
            kAXTitleAttribute as CFString,
            kAXDescriptionAttribute as CFString,
            kAXValueAttribute as CFString,
            kAXHelpAttribute as CFString,
        ]
        let childAttributes: [CFString] = [
            kAXChildrenAttribute as CFString,
            kAXVisibleChildrenAttribute as CFString,
            kAXWindowsAttribute as CFString,
        ]

        while let (element, depth) = stack.popLast(), visited < 700 {
            visited += 1
            var texts: [String] = []
            for attribute in textAttributes {
                if let text = accessibilityText(attribute, from: element) {
                    texts.append(text)
                }
            }
            let joined = texts.joined(separator: " ")
            if !joined.isEmpty, let unread = unreadInfo(from: joined, requiresWeChatName: requiresWeChatName) {
                hasUnread = true
                if let count = unread.count {
                    bestCount = max(bestCount ?? 0, count)
                }
            }

            guard depth < 6 else { continue }
            for attribute in childAttributes {
                guard let value = copyAccessibilityAttribute(attribute, from: element) else { continue }
                if CFGetTypeID(value) == AXUIElementGetTypeID() {
                    stack.append((value as! AXUIElement, depth + 1))
                } else if let children = value as? [AXUIElement] {
                    for child in children.reversed() {
                        stack.append((child, depth + 1))
                    }
                }
            }
        }
        return hasUnread ? WeChatUnreadSnapshot(hasUnread: true, count: bestCount, source: source) : nil
    }

    private static func copyAccessibilityAttribute(_ attribute: CFString, from element: AXUIElement) -> CFTypeRef? {
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(element, attribute, &value)
        guard result == .success else { return nil }
        return value
    }

    private static func accessibilityText(_ attribute: CFString, from element: AXUIElement) -> String? {
        guard let value = copyAccessibilityAttribute(attribute, from: element) else { return nil }
        if let text = value as? String {
            return text
        }
        if let attributed = value as? NSAttributedString {
            return attributed.string
        }
        if let number = value as? NSNumber {
            return number.stringValue
        }
        return nil
    }

    // MARK: 微信探测诊断(临时取证)
    // 把 Dock 与微信辅助功能树里所有"有信息量"的字段(含专放角标的 AXStatusLabel)dump 到 /tmp/claudepet.log,
    // 据真实字样对症修探测规则。临时手段:定准规则后连同 --wechat-dump 与菜单项一并移除。
    fileprivate static func dumpWeChatAccessibilityTree() {
        log("==== 微信探测诊断开始 ====")
        guard accessibilityTrusted(prompt: true) else {
            log("诊断中止:辅助功能未授权")
            return
        }
        let apps = NSWorkspace.shared.runningApplications
        if let dock = apps.first(where: { $0.bundleIdentifier == "com.apple.dock" }) {
            log("---- 来源 Dock(pid=\(dock.processIdentifier)) ----")
            dumpTree(AXUIElementCreateApplication(dock.processIdentifier), source: "Dock")
        } else {
            log("未发现 Dock 进程")
        }
        let weChatApps = apps.filter { app in
            let bundle = app.bundleIdentifier?.lowercased() ?? ""
            let name = app.localizedName?.lowercased() ?? ""
            return bundle.contains("wechat") || bundle.contains("xinwechat") || name.contains("wechat") || name.contains("微信")
        }
        if weChatApps.isEmpty { log("未发现微信进程") }
        for app in weChatApps {
            log("---- 来源 \(app.localizedName ?? "微信")(bundle=\(app.bundleIdentifier ?? "?")) ----")
            dumpTree(AXUIElementCreateApplication(app.processIdentifier), source: app.localizedName ?? "微信")
        }
        log("==== 微信探测诊断结束 ====")
    }

    private static func dumpTree(_ root: AXUIElement, source: String) {
        let dumpAttributes: [(String, CFString)] = [
            ("role", kAXRoleAttribute as CFString),
            ("roleDesc", kAXRoleDescriptionAttribute as CFString),
            ("title", kAXTitleAttribute as CFString),
            ("desc", kAXDescriptionAttribute as CFString),
            ("value", kAXValueAttribute as CFString),
            ("help", kAXHelpAttribute as CFString),
            ("statusLabel", "AXStatusLabel" as CFString),
            ("id", kAXIdentifierAttribute as CFString),
        ]
        let childAttributes: [CFString] = [
            kAXChildrenAttribute as CFString,
            kAXVisibleChildrenAttribute as CFString,
            kAXWindowsAttribute as CFString,
        ]
        let keywords = ["未读", "消息", "通知", "新", "项目", "条", "badge", "unread", "message", "new", "item", "dot"]
        var stack: [(AXUIElement, Int)] = [(root, 0)]
        var visited = 0
        var logged = 0
        while let (element, depth) = stack.popLast(), visited < 4000, logged < 250 {
            visited += 1
            var fields: [String] = []
            var joined = ""
            for (name, attribute) in dumpAttributes {
                if let text = accessibilityText(attribute, from: element), !text.isEmpty {
                    fields.append("\(name)=「\(text)」")
                    joined += " " + text
                }
            }
            if !fields.isEmpty {
                let lower = joined.lowercased()
                let mentionsWeChat = lower.contains("wechat") || joined.contains("微信")
                let hasDigit = joined.unicodeScalars.contains { CharacterSet.decimalDigits.contains($0) }
                let hasKeyword = keywords.contains { joined.contains($0) || lower.contains($0.lowercased()) }
                if hasDigit || mentionsWeChat || hasKeyword {
                    logged += 1
                    log("[\(source) d\(depth)] " + fields.joined(separator: " "))
                }
            }
            guard depth < 8 else { continue }
            for attribute in childAttributes {
                guard let value = copyAccessibilityAttribute(attribute, from: element) else { continue }
                if CFGetTypeID(value) == AXUIElementGetTypeID() {
                    stack.append((value as! AXUIElement, depth + 1))
                } else if let children = value as? [AXUIElement] {
                    for child in children.reversed() {
                        stack.append((child, depth + 1))
                    }
                }
            }
        }
        log("[\(source)] 遍历节点=\(visited) 记录=\(logged)")
    }

    /// 真·未读量词:必须紧跟在数字后面才算未读信号。Dock 角标念作"N 个新项目 / N new items",
    /// 明确未读标签念作"N 条未读 / N unread"。刻意不收"消息""通知"这类微信界面常驻词——
    /// 那些词只要微信开着就恒在,会把"有界面"误判成"有未读",正是已读后仍刷屏的祸根。
    private static let unreadUnitPhrases = ["个新项目", "新项目", "条未读", "个未读", "未读",
                                            "new items", "new item", "unread"]

    private static func unreadInfo(from text: String, requiresWeChatName: Bool) -> WeChatUnreadInfo? {
        let lower = text.lowercased()
        let mentionsWeChat = lower.contains("wechat") || text.contains("微信")
        guard !requiresWeChatName || mentionsWeChat else { return nil }
        // 只认"数字 + 未读量词"紧邻出现的结构化未读,数字必须贴着量词;
        // 不再把文本里任意第一个整数(时间/群人数/版本号)当条数。
        return unreadCountFromBadgePhrase(in: text)
    }

    /// 扫描"数字紧跟未读量词"的角标短语(如"3 个新项目""5 unread"),取其中最大数字为未读条数。
    private static func unreadCountFromBadgePhrase(in text: String) -> WeChatUnreadInfo? {
        let scalars = Array(text.unicodeScalars)
        var index = 0
        var best: Int?
        while index < scalars.count {
            guard CharacterSet.decimalDigits.contains(scalars[index]) else {
                index += 1
                continue
            }
            var digits = ""
            while index < scalars.count, CharacterSet.decimalDigits.contains(scalars[index]) {
                digits.append(String(scalars[index]))
                index += 1
            }
            // 跳过数字与量词间的空白(普通空格/不换行空格等),量词须紧随其后
            var tail = index
            while tail < scalars.count, CharacterSet.whitespaces.contains(scalars[tail]) {
                tail += 1
            }
            let rest = String(String.UnicodeScalarView(scalars[tail...])).lowercased()
            if let value = Int(digits), value > 0,
               unreadUnitPhrases.contains(where: { rest.hasPrefix($0) }) {
                best = max(best ?? 0, value)
            }
        }
        guard let best else { return nil }
        return WeChatUnreadInfo(count: best)
    }

    // MARK: 进食动画:拖入文件时张嘴咀嚼,离开/吃下即闭嘴
    // 用 Timer(.common 模式)手动切帧:拖放期间 runloop 处于 eventTracking,
    // 普通定时器与部分隐式动画不会触发,.common 才能保证“嚼”起来。
    private func startEating() {
        Self.log("startEating")
        noteInteraction()                                // 喂/嚼 = 被搭理,回血
        guard chewTimer == nil else { return }
        mouthOpen = 1
        render()                                         // 立即张嘴,给即时反馈
        let timer = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.mouthOpen = self.mouthOpen > 0 ? 0 : 1  // 在张/闭间切换,切出"咀嚼"
            self.render()
        }
        RunLoop.main.add(timer, forMode: .common)
        chewTimer = timer
    }

    private func stopEating() {
        chewTimer?.invalidate()
        chewTimer = nil
        mouthOpen = 0
        render()                                         // 复位到闭嘴常态
    }

    // MARK: 快捷键投喂:原地"吃一口"
    // 没有拖放过程,故张嘴咀嚼一阵后用定时器自动闭嘴收尾;连按则顺延收尾,不会半路停。
    func eatBite() {
        setFeedGlow(true)
        startEating()                                    // 已在嚼则内部 guard 忽略,不重启
        biteTimer?.invalidate()                          // 重置收尾计时,支持连按顺延
        let timer = Timer(timeInterval: 1.0, repeats: false) { [weak self] _ in
            self?.stopEating()
            self?.setFeedGlow(self?.isHovering == true) // 悬停中则保留发光,否则熄灭
            self?.biteTimer = nil
        }
        RunLoop.main.add(timer, forMode: .common)
        biteTimer = timer
    }

    // MARK: 鼠标悬停互动
    // 借 NSTrackingArea 捕获进/出。.activeAlways 让附件应用(非前台)也能收到 hover。
    // 悬停期间:开心跳一下 + 放大版呼吸 + 眯眼笑 + 发光,并暂停空闲打扰;移出即复位。
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea) // 尺寸变化时重建,避免叠加多个
        // 只在星芒身体上响应 hover——窗口为容纳自适应横幅留了大片顶部透明区,不该一碰就笑
        addTrackingArea(NSTrackingArea(
            rect: petFrameInBounds,
            options: [.activeAlways, .mouseEnteredAndExited],
            owner: self
        ))
    }

    override func mouseEntered(with event: NSEvent) {
        guard !isHovering else { return }
        noteInteraction()                // 摸一下 = 被搭理,回血
        isHovering = true
        eyeMode = .happy                 // 眯眼笑
        render()
        setFeedGlow(true)                // 点亮橙光
        applyBreathing()                 // 鼓起来:放大版呼吸(悬停最优先)
        jump()                           // 开心蹦一下
    }

    override func mouseExited(with event: NSEvent) {
        guard isHovering else { return }
        isHovering = false
        eyeMode = .normal
        render()
        if chewTimer == nil { setFeedGlow(false) } // 进食中则交给进食收尾,避免抢着熄灯
        applyBreathing()                 // 退出悬停:回到专注(若在陪跑)或常态呼吸
    }

    // MARK: 点击互动
    // mouseUp 按落点分流:可点横幅 → 回现场;双击身体 → 弹输入框问 Claude;单击身体 → 吃一口。
    // 仍不 override mouseDown,保留 isMovableByWindowBackground 整窗拖拽。
    override func mouseUp(with event: NSEvent) {
        let pt = convert(event.locationInWindow, from: nil)
        Self.log("mouseUp pt=\(NSStringFromPoint(pt)) opacity=\(bannerLayer.opacity) cwd=\(bannerActionCwd ?? "nil") banner=\(NSStringFromRect(bannerLayer.frame)) hitBanner=\(bannerLayer.frame.contains(pt)) hitBody=\(petFrameInBounds.contains(pt))")
        // 横幅正显示且带目录 → 点它回到那摊的终端/目录现场
        if bannerLayer.opacity > 0, let cwd = bannerActionCwd, bannerLayer.frame.contains(pt) {
            returnToScene(cwd: cwd, tty: bannerActionTty)
            return
        }
        // 双击身体 → 弹输入框,喂一句话/一段报错给 Claude
        if event.clickCount >= 2, petFrameInBounds.contains(pt) {
            promptAndFeed(tool: .claude)
            return
        }
        // 单击身体 → 嚼一口(点窗口顶部为容纳横幅留的透明区不再误触发)
        if petFrameInBounds.contains(pt) {
            eatBite()
        }
    }

    /// 点报喜/等确认横幅 → 回到那摊的现场。优先级:
    /// 1) 带 tty 时按 tty 精确 focus 到承载该会话的终端窗口(Ghostty / iTerm2 / Terminal.app 各自脚本);
    /// 2) 没命中(tty 缺失 / 窗口已关 / 该终端没在跑)→ 退回把任一在跑的终端 App 整窗唤前台;
    /// 3) 仍无终端 → Finder 打开该目录;4) 目录也无效 → beep。只激活/打开,绝不改动任何文件。
    /// osascript 起子进程可能有几十毫秒耗时,放后台跑,避免点一下卡住桌宠;真正激活落回主线程。
    private func returnToScene(cwd: String, tty: String?) {
        noteInteraction()
        let normTty = (tty?.isEmpty == false) ? tty : nil
        Self.log("returnToScene 进入 cwd=\(cwd) tty=\(normTty ?? "nil")")
        DispatchQueue.global(qos: .userInitiated).async {
            if let normTty, PetView.focusTerminalSurface(tty: normTty) {
                Self.log("returnToScene 按 tty 精确命中 \(normTty)")
                return
            }
            DispatchQueue.main.async { self.activateAnyTerminalOrOpen(cwd: cwd) }
        }
    }

    /// tty 没命中时的退路:把任一在跑的终端 App 整窗唤前台,没有终端则用 Finder 打开目录,目录也无效则 beep。
    /// 这是 tty 精确定位之前的旧行为,保留作兜底,保证功能不哑火。
    private func activateAnyTerminalOrOpen(cwd: String) {
        let termBundleIds = ["com.mitchellh.ghostty", "com.apple.Terminal", "com.googlecode.iterm2"]
        if let app = NSWorkspace.shared.runningApplications.first(where: {
            guard let id = $0.bundleIdentifier else { return false }
            return termBundleIds.contains(id)
        }) {
            Self.log("returnToScene 退回整窗激活终端 \(app.bundleIdentifier ?? "?")")
            // NSRunningApplication.activate() 从 LSUIElement 后台应用去激活别的 App 常被系统忽略;
            // 改用 openApplication(activates:true) 强制把终端 App 唤到前台,不受后台抢焦点限制。
            if let url = app.bundleURL {
                let config = NSWorkspace.OpenConfiguration()
                config.activates = true
                NSWorkspace.shared.openApplication(at: url, configuration: config)
            } else {
                app.activate(options: [.activateAllWindows])
            }
            return
        }
        if !cwd.isEmpty, FileManager.default.fileExists(atPath: cwd) {
            Self.log("returnToScene 无终端在跑,Finder 打开 \(cwd)")
            NSWorkspace.shared.open(URL(fileURLWithPath: cwd))   // 没终端在跑:用 Finder 打开目录
        } else {
            Self.log("returnToScene cwd 无效,beep")
            NSSound.beep()
        }
    }

    /// 按 tty 精确定位承载该会话的终端窗口并唤到前台。只查询正在跑的终端(避免 tell 唤起未运行的 App),
    /// 依次试 Ghostty / iTerm2 / Terminal.app,任一命中即返回 true。命中标准:脚本回 "ok"。
    /// tty 只接受 /dev/tty 前缀,既是格式校验也防 URL 注入 AppleScript。
    static func focusTerminalSurface(tty: String) -> Bool {
        guard tty.hasPrefix("/dev/tty") else { return false }
        let running = Set(NSWorkspace.shared.runningApplications.compactMap { $0.bundleIdentifier })
        let candidates: [(String, String)] = [
            ("com.mitchellh.ghostty", ghosttyFocusScript(tty: tty)),
            ("com.googlecode.iterm2", itermFocusScript(tty: tty)),
            ("com.apple.Terminal", terminalFocusScript(tty: tty)),
        ]
        for (bundleId, script) in candidates where running.contains(bundleId) {
            if runAppleScript(script) == "ok" {
                Self.log("focusTerminalSurface 命中 \(bundleId) tty=\(tty)")
                return true
            }
        }
        return false
    }

    /// Ghostty:新版脚本字典里 terminal 暴露 tty 且响应 focus;遍历 surface 按 tty 匹配,命中即 focus + activate。
    private static func ghosttyFocusScript(tty: String) -> String {
        """
        tell application "Ghostty"
          repeat with t in terminals
            if (tty of t) is "\(tty)" then
              focus t
              activate
              return "ok"
            end if
          end repeat
        end tell
        return "no"
        """
    }

    /// iTerm2:session 带 tty;命中后 select 到该 session 与所在 tab,再 activate 把窗口唤前台。
    private static func itermFocusScript(tty: String) -> String {
        """
        tell application "iTerm2"
          repeat with w in windows
            repeat with t in tabs of w
              repeat with s in sessions of t
                if (tty of s) is "\(tty)" then
                  select s
                  select t
                  set index of w to 1
                  activate
                  return "ok"
                end if
              end repeat
            end repeat
          end repeat
        end tell
        return "no"
        """
    }

    /// Terminal.app:tab 带 tty;命中后把该 tab 设为窗口选中页并置前,再 activate。
    private static func terminalFocusScript(tty: String) -> String {
        """
        tell application "Terminal"
          repeat with w in windows
            repeat with t in tabs of w
              if (tty of t) is "\(tty)" then
                set selected tab of w to t
                set frontmost of w to true
                activate
                return "ok"
              end if
            end repeat
          end repeat
        end tell
        return "no"
        """
    }

    /// 跑一段 AppleScript,返回 stdout(去空白)。沿用 finderSelectionPaths 的 osascript 子进程套路,吞掉报错。
    private static func runAppleScript(_ script: String) -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", script]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()                   // 吞掉报错(如某终端未授权自动化),不污染判定
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return ""
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    /// 双击桌宠 / 右键"问 Claude·Codex" → 弹多行输入框,把主公打的字或贴的报错喂去开会话(在家目录)。
    /// 复用投喂同一套脚本与 cc/cx 候选;只读输入文本,不碰任何文件。
    func promptAndFeed(tool: FeedTool) {
        NSApp.activate(ignoringOtherApps: true)            // 附件应用须先激活,弹框才抢得到键盘焦点
        let who = (tool == .codex) ? "Codex" : "Claude"
        let alert = NSAlert()
        alert.messageText = "喂给 \(who) 一句话"
        alert.informativeText = "打一句话,或贴一段报错——小的叼去在家目录开个会话。"
        alert.addButton(withTitle: "投喂")
        alert.addButton(withTitle: "算了")
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 320, height: 96))
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        let textView = NSTextView(frame: scroll.bounds)
        textView.font = .systemFont(ofSize: 13)
        textView.isRichText = false
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        scroll.documentView = textView
        alert.accessoryView = scroll
        alert.window.initialFirstResponder = textView
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let text = textView.string
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { NSSound.beep(); return }
        eatBite()                                          // 嚼一口给即时反馈
        PetView.analyzeText(text, with: tool)
    }

    // MARK: 图层小动作(只动 transform,不动窗口)
    // 跳/摇晃/伸懒腰都改图层 transform 的不同分量:窗口不动,鼠标 hover 跟踪稳定,且与呼吸(scale)分量叠加不冲突。

    /// 开心跳一下:transform.translation.y 抛物线起落一次(正 y 向上)。
    private func jump() {
        let j = CAKeyframeAnimation(keyPath: "transform.translation.y")
        j.values = [0, Style.windowSize * 0.16, 0]
        j.keyTimes = [0, 0.4, 1]
        j.timingFunctions = [CAMediaTimingFunction(name: .easeOut), CAMediaTimingFunction(name: .easeIn)]
        j.duration = 0.45
        iconLayer.add(j, forKey: "jump")
    }

    /// 扑食滑行期间切换跑步腿相位;腿本身仍由 starImage 画进同一帧,不新增图层。
    private func startRunningLegs() {
        guard runTimer == nil else { return }
        runPhase = 1
        render()
        let timer = Timer(timeInterval: 0.16, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.runPhase = self.runPhase == 1 ? 2 : 1
            self.render()
        }
        RunLoop.main.add(timer, forMode: .common)
        runTimer = timer
    }

    private func stopRunningLegs() {
        runTimer?.invalidate()
        runTimer = nil
        runPhase = 0
        render()
    }

    /// 左右摇晃:transform.rotation.z 来回摆几下(弧度),与呼吸 scale 互不干扰。
    private func sway() {
        let s = CAKeyframeAnimation(keyPath: "transform.rotation.z")
        s.values = [0, 0.12, -0.10, 0.07, -0.04, 0]
        s.keyTimes = [0, 0.18, 0.42, 0.64, 0.84, 1]
        s.duration = 1.1
        s.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        iconLayer.add(s, forKey: "sway")
    }

    /// 打哈欠/伸懒腰:闭眼 + 张嘴一阵,同时纵向(scale.y)缓缓拉伸再收回。
    /// 纵向拉伸用 transform.scale.y,与呼吸的 transform.scale 是不同 keyPath,可叠加合成不互相覆盖。
    private func yawn() {
        guard chewTimer == nil else { return } // 正在嚼就不哈欠,免得抢嘴
        eyeMode = .closed
        mouthOpen = 1
        render()
        let stretch = CAKeyframeAnimation(keyPath: "transform.scale.y")
        stretch.values = [1.0, 1.12, 1.12, 1.0]
        stretch.keyTimes = [0, 0.3, 0.7, 1]
        stretch.duration = 1.0
        stretch.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        iconLayer.add(stretch, forKey: "yawn")
        let done = Timer(timeInterval: 1.0, repeats: false) { [weak self] _ in
            guard let self else { return }
            self.mouthOpen = 0
            self.eyeMode = self.isHovering ? .happy : .normal
            self.render()
        }
        RunLoop.main.add(done, forMode: .common)
    }

    /// 眨一下眼:闭眼极短再睁开;空闲期间偶发,接管眼睛防 eyeFollow 抢渲染。
    private func blink() {
        guard eyeMode == .normal else { return } // 笑眼/闭眼时不叠加
        idleEyeActive = true
        eyeMode = .closed
        render()
        let open = Timer(timeInterval: 0.13, repeats: false) { [weak self] _ in
            guard let self else { return }
            self.eyeMode = .normal
            self.render()
            self.idleEyeActive = false
        }
        RunLoop.main.add(open, forMode: .common)
    }

    /// 东张西望:接管眼睛,依次随机看几个方向,结束后交还鼠标跟随。
    private func lookAround() {
        guard eyeMode == .normal, !idleEyeActive else { return }
        idleEyeActive = true
        let dirs = [CGVector(dx: -0.9, dy: 0.2), CGVector(dx: 0.9, dy: 0.1),
                    CGVector(dx: 0.2, dy: -0.8), CGVector(dx: -0.5, dy: 0.6)].shuffled()
        let picks = Array(dirs.prefix(3))
        for (i, dir) in picks.enumerated() {
            let t = Timer(timeInterval: 0.45 * Double(i), repeats: false) { [weak self] _ in
                self?.eyeLook = dir
                self?.render()
            }
            RunLoop.main.add(t, forMode: .common)
        }
        let end = Timer(timeInterval: 0.45 * Double(picks.count) + 0.3, repeats: false) { [weak self] _ in
            self?.idleEyeActive = false // 交还鼠标跟随,eyeFollow 会平滑拉回
        }
        RunLoop.main.add(end, forMode: .common)
    }

    // MARK: 空闲动作调度
    // 久无操作时每隔几秒随机挑一个小动作;但 hover/进食/扑食/眼睛被接管时一律让路,不打扰交互。
    private func scheduleIdle() {
        idleTimer?.invalidate()
        let delay = Double.random(in: 5...11)
        let t = Timer(timeInterval: delay, repeats: false) { [weak self] _ in
            self?.performRandomIdle()
            self?.scheduleIdle()
        }
        RunLoop.main.add(t, forMode: .common)
        idleTimer = t
    }

    private func performRandomIdle() {
        guard !isHovering, !isPouncing, !isWorking, !isDrooping, chewTimer == nil, biteTimer == nil, !idleEyeActive else { return }
        var actions = [blink, blink, lookAround, sway, yawn] // blink 权重高些,最自然
        if Settings.petNightDrowsy, Self.isLateNight() {
            actions = [yawn, yawn, blink, lookAround]         // 深夜:多打哈欠犯困
        }
        actions.randomElement()?()
    }

    // MARK: 陪跑指示灯(随 Claude/Codex 生命周期事件:开工进专注、等确认提醒、收工庆祝)
    // 多终端并发按 sid 聚合:任意会话在跑就保持专注,全部收工才歇;某会话崩了没发 done 由超时清理兜底。
    private static let runningAccent = NSColor(srgbRed: 0.20, green: 0.78, blue: 0.35, alpha: 0.95) // 系统绿,正在干活
    private static let waitingAccent = NSColor(srgbRed: 0.96, green: 0.65, blue: 0.14, alpha: 0.95) // 琥珀黄,醒目催点头

    /// 陪跑事件入口(由 AppDelegate 解析 claudepet:// 后调用)。phase ∈ start|waiting|done;cwd 供横幅"点回现场",tty 供精确回窗口,ts 供乱序定序。
    func handleCompanionEvent(phase: String, sid: String, message: String, cwd: String?, tty: String?, ts: Double?, pid: pid_t?, suppressBanner: Bool) {
        // 事件按"生成时间戳"定序,免疫 LaunchServices 的乱序投递:同一 sid 收到比已处理更旧的事件即丢弃,
        // 旧轮迟到的 done/waiting 不再污染新轮(老 hook 不带 ts 时退化为不去重,功能不哑火)。
        if let ts {
            if let prev = lastEventAt[sid], ts < prev {
                Self.log("陪跑事件乱序丢弃:ts=\(ts) < 已处理 \(prev) sid=\(sid) phase=\(phase)")
                return
            }
            lastEventAt[sid] = ts
        }
        switch phase {
        case "start":
            guard Settings.petFocusOnStart else { return }
            activeSessions[sid] = SessionInfo(at: Date(), waiting: false, pid: pid)   // 正在执行 →「跑」,记进程 pid 供探活
            startSessionSweep()
            updateSessionBadge()
            applyBreathing()                // 有在跑的 → 专注呼吸
        case "waiting":
            // 「等」只认"会话还在跑(未结束)时停下等你"——即 done 之前的 waiting(要权限 / Claude 主动提问),
            // 那才是真需要主公填写或确认。done 之后才来的 waiting(答完闲等输入)→会话已移除→整个忽略:不标等、不弹横幅。
            // 乱序的尾随 waiting 已被上方 ts 定序挡掉,这里不再需要时间宽限窗。
            guard Settings.petFocusOnStart, activeSessions[sid] != nil else { return }
            activeSessions[sid] = SessionInfo(at: Date(), waiting: true, pid: pid ?? activeSessions[sid]?.pid)
            updateSessionBadge()
            applyBreathing()
            guard Settings.petNotifyOnWaiting, !suppressBanner else { return }
            flashNotice(message, accent: Self.waitingAccent, actionCwd: cwd, actionTty: tty)
        case "done":
            // 已回答完毕 = 结束 → 移除、不再显示(不论此前是「跑」还是「等」)。lastEventAt 保留,继续为后续乱序事件定序。
            if activeSessions.removeValue(forKey: sid) != nil {
                updateSessionBadge()
                applyBreathing()            // 收工 → 退专注
            }
            if Settings.receiveTaskDoneNotifications, !suppressBanner {
                showTaskDoneHint(message: message, actionCwd: cwd, actionTty: tty)           // 报喜横幅(带目录/任务/tty),点它回现场
            }
        default:
            break
        }
    }

    private func startSessionSweep() {
        guard sessionSweepTimer == nil else { return }
        // 15s 一轮:进程退出后最多 15s 清掉角标(kill -0 极轻,纯 syscall),比原 60s 更跟手。
        let t = Timer(timeInterval: 15, repeats: true) { [weak self] _ in self?.sweepStaleSessions() }
        RunLoop.main.add(t, forMode: .common)   // .common:拖放/事件跟踪期间也照常清理
        sessionSweepTimer = t
    }

    /// 清理失活会话并兜底:有进程 pid 的以"进程是否存活"为准(进程退出即清,根治硬退出/崩溃/被杀不发 done 的卡死),
    /// 无 pid 的(老 hook)退回 10 分钟超时兜底;清空后停表并退专注。
    private func sweepStaleSessions() {
        let now = Date()
        lastEventAt = lastEventAt.filter { now.timeIntervalSince1970 - $0.value < 1800 }   // 清理陈旧定序记录,免无界增长(与会话硬上限对齐)
        guard !activeSessions.isEmpty else {
            sessionSweepTimer?.invalidate(); sessionSweepTimer = nil; return
        }
        let before = activeSessions.count
        activeSessions = activeSessions.filter { _, info in
            if let pid = info.pid {
                // 进程已退出 → 立即清(硬退出/崩溃/被杀/关终端都不触发收工钩子,这是唯一兜得住的信号);
                // 进程仍在 → 保留,不受 10 分钟限(根治长任务无中间事件被误清);30 分钟硬上限兜 pid 复用与僵死。
                if !Self.processAlive(pid) { return false }
                return now.timeIntervalSince(info.at) < 1800
            }
            return now.timeIntervalSince(info.at) < 600   // 无 pid(老 hook):退回纯超时兜底
        }
        if activeSessions.count != before {
            updateSessionBadge()       // 清了失活会话 → 刷新角标
            applyBreathing()           // 在跑的可能被清掉 → 同步呼吸
        }
        if activeSessions.isEmpty {
            sessionSweepTimer?.invalidate(); sessionSweepTimer = nil
        }
    }

    /// 进程是否仍存活:kill(pid,0) 不真发信号,仅探存在性。0=存在;-1 且 errno==EPERM 仍算存在(无权发信号);
    /// -1 且 errno==ESRCH 才是真没了。纯 syscall,sweep 主线程调用无阻塞。
    private static func processAlive(_ pid: pid_t) -> Bool {
        guard pid > 0 else { return false }
        if kill(pid, 0) == 0 { return true }
        return errno == EPERM
    }

    /// 刷新并发会话角标:显示"跑N·等N"(跑=在干活、等=答完候你),按 petShowSessionBadge 开关显隐。
    /// 内容是现画的小图,贴星芒右上角、挂 view.layer(不随星芒跳动);纯本地状态,不受免打扰影响。
    private func updateSessionBadge() {
        let running = activeSessions.values.filter { !$0.waiting }.count
        let waiting = activeSessions.values.filter { $0.waiting }.count
        guard Settings.petShowSessionBadge, running + waiting > 0 else {   // 开关关 / 无会话:藏起来
            CATransaction.begin(); CATransaction.setDisableActions(true)
            badgeLayer.opacity = 0
            CATransaction.commit()
            return
        }
        let image = Self.sessionBadgeImage(running: running, waiting: waiting)
        let s = image.size
        CATransaction.begin(); CATransaction.setDisableActions(true)
        badgeLayer.contents = image.cgImage(forProposedRect: nil, context: nil, hints: nil)
        badgeLayer.frame = CGRect(x: petFrameInBounds.maxX - s.width + 3,
                                  y: petFrameInBounds.maxY - s.height + 3,
                                  width: s.width, height: s.height)   // 浮在星芒右上角
        badgeLayer.opacity = 1
        CATransaction.commit()
    }

    // 角标点阵字形:跟星芒同款硬边方块美学,逐格 fill,不走字体、不抗锯齿。
    // 统一 5 格高;"1"=填、" "=空。跑=右向三角(运行/前进)、等=沙漏(候着)。
    private static let badgeRunIcon = [
        "1  ",
        "11 ",
        "111",
        "11 ",
        "1  ",
    ]
    private static let badgeWaitIcon = [
        "11111",
        " 111 ",
        "  1  ",
        " 111 ",
        "11111",
    ]
    private static let badgeDigitGlyphs: [[String]] = [
        ["111", "1 1", "1 1", "1 1", "111"], // 0
        [" 1 ", "11 ", " 1 ", " 1 ", "111"], // 1
        ["111", "  1", "111", "1  ", "111"], // 2
        ["111", "  1", "111", "  1", "111"], // 3
        ["1 1", "1 1", "111", "  1", "  1"], // 4
        ["111", "1  ", "111", "  1", "111"], // 5
        ["111", "1  ", "111", "1 1", "111"], // 6
        ["111", "  1", "  1", "  1", "  1"], // 7
        ["111", "1 1", "111", "1 1", "111"], // 8
        ["111", "1 1", "111", "  1", "111"], // 9
    ]

    /// 画会话角标小图:像素风。跑=绿三角、等=琥珀沙漏,各跟 3x5 点阵数字;逐格 fill、每格深描边。
    static func sessionBadgeImage(running: Int, waiting: Int) -> NSImage {
        var groups: [(icon: [String], color: NSColor, count: Int)] = []
        if running > 0 { groups.append((icon: badgeRunIcon, color: runningAccent, count: running)) }
        if waiting > 0 { groups.append((icon: badgeWaitIcon, color: waitingAccent, count: waiting)) }
        guard !groups.isEmpty else { return NSImage(size: CGSize(width: 1, height: 1)) }
        let px: CGFloat = 3
        let rows = 5
        let glyphGap = 1
        let groupGap = 3
        let pad: CGFloat = 3
        func cols(_ g: [String]) -> Int { g.map { $0.count }.max() ?? 0 }
        func digits(_ n: Int) -> [[String]] { String(n).compactMap { $0.wholeNumberValue }.map { badgeDigitGlyphs[$0] } }
        var tc = 0
        for (gi, g) in groups.enumerated() {
            tc += cols(g.icon)
            for d in digits(g.count) { tc += glyphGap + cols(d) }
            if gi < groups.count - 1 { tc += groupGap }
        }
        let size = CGSize(width: pad * 2 + CGFloat(tc) * px, height: pad * 2 + CGFloat(rows) * px)
        let image = NSImage(size: size)
        image.lockFocus()
        defer { image.unlockFocus() }
        guard let ctx = NSGraphicsContext.current?.cgContext else { return image }
        func draw(_ glyph: [String], at sc: Int, color: NSColor) {
            func cell(_ r: Int, _ c: Int) -> CGRect { CGRect(x: pad + CGFloat(sc + c) * px, y: pad + CGFloat(rows - 1 - r) * px, width: px, height: px) }
            ctx.setFillColor(NSColor.black.withAlphaComponent(0.55).cgColor)
            for (r, line) in glyph.enumerated() { for (c, ch) in line.enumerated() where ch != " " { ctx.fill(cell(r, c).insetBy(dx: -1, dy: -1)) } }
            ctx.setFillColor(color.cgColor)
            for (r, line) in glyph.enumerated() { for (c, ch) in line.enumerated() where ch != " " { ctx.fill(cell(r, c)) } }
        }
        var col = 0
        for (gi, g) in groups.enumerated() {
            draw(g.icon, at: col, color: g.color)
            col += cols(g.icon)
            for d in digits(g.count) {
                col += glyphGap
                draw(d, at: col, color: NSColor.white.withAlphaComponent(0.96))
                col += cols(d)
            }
            if gi < groups.count - 1 { col += groupGap }
        }
        return image
    }

    // MARK: 作息脾气(会饿会蔫 / 久坐提醒 / 深夜犯困)
    // 都接现有呼吸/空闲/横幅:蔫=慢呼吸+垂眼、久坐=定时横幅、深夜=空闲多打哈欠。纯本地,无权限。
    /// 被搭理(摸/喂/嚼):刷新互动时刻,蔫着就回血。
    private func noteInteraction() {
        lastInteractionAt = Date()
        if isDrooping { reviveFromDroop() }
    }

    private func reviveFromDroop() {
        isDrooping = false
        idleEyeActive = false
        eyeLook = .zero
        eyeMode = isHovering ? .happy : .normal
        render()
        applyBreathing()
    }

    private func startMoodTimer() {
        guard moodTimer == nil else { return }
        let t = Timer(timeInterval: 60, repeats: true) { [weak self] _ in self?.checkMood() }
        RunLoop.main.add(t, forMode: .common)
        moodTimer = t
    }

    /// 久无互动则蔫;关了开关或正忙/悬停/进食/陪跑时一律让路。
    private func checkMood() {
        if !Settings.petMoodDecay {
            if isDrooping { reviveFromDroop() }
            return
        }
        guard !isDrooping, !isHovering, !isPouncing, !isWorking, chewTimer == nil, biteTimer == nil else { return }
        if Date().timeIntervalSince(lastInteractionAt) > Self.moodDecaySeconds { enterDroop() }
    }

    private func enterDroop() {
        isDrooping = true
        idleEyeActive = true                       // 接管眼睛垂下,防 eyeFollow 拉回
        eyeMode = .normal
        eyeLook = CGVector(dx: 0, dy: -0.7)        // 眼神朝下,无精打采
        render()
        applyBreathing()                           // 切慢呼吸(缩着)
    }

    /// 久坐提醒:固定间隔弹横幅催起身。受开关与间隔(分钟)控制,设置改后由 handleBehaviorDidChange 重配。
    private func startSedentaryTimerIfNeeded() {
        sedentaryTimer?.invalidate(); sedentaryTimer = nil
        guard Settings.petSedentaryReminder else { return }
        let interval = TimeInterval(Settings.petSedentaryMinutes * 60)
        let t = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            self?.flashNotice("久坐了,起来动动,主公", accent: Self.waitingAccent)
        }
        RunLoop.main.add(t, forMode: .common)
        sedentaryTimer = t
    }

    @objc private func handleBehaviorDidChange(_ notification: Notification) {
        startSedentaryTimerIfNeeded()                                // 久坐开关/间隔变化 → 重配
        if !Settings.petMoodDecay, isDrooping { reviveFromDroop() }  // 关了会饿 → 立即回血
        updateSessionBadge()                                         // 会话角标开关变化 → 立即显隐
    }

    private static func isLateNight() -> Bool {
        let h = Calendar.current.component(.hour, from: Date())
        return h >= 23 || h < 5
    }

    // MARK: 划词翻译(选中文字 → ⌥⌘T → 取词 → cc/claude 翻译 → 头顶气泡)
    // 引擎复用投喂同一套 cc/claude 候选;取词只读不改选中内容,翻译纯文本不触发任何权限确认。
    private static let translateAccent = NSColor(srgbRed: 0.30, green: 0.68, blue: 0.92, alpha: 0.95) // 天青,区别于微信绿/任务橙
    private var isTranslating = false   // 防重入:翻译中再按 ⌥⌘T 直接忽略,免并发起多个进程、气泡打架

    /// ⌥⌘T 入口:开关关了或正翻着都让路;取到选中文字→边嚼边等→译文回来弹气泡。取词与翻译都在后台,UI 回主线程。
    func translateSelection() {
        guard Settings.petTranslate, !isTranslating else { return }
        guard Self.accessibilityTrusted(prompt: true) else {   // 没授权:弹系统授权框,本轮先放弃
            Self.log("划词翻译:辅助功能未授权")
            return
        }
        isTranslating = true
        DispatchQueue.global(qos: .userInitiated).async {
            let text = Self.selectedText()
            guard let text, !text.isEmpty else {
                DispatchQueue.main.async { self.isTranslating = false; NSSound.beep() }  // 没选中文字:响一声示意
                return
            }
            DispatchQueue.main.async { self.setFeedGlow(true); self.startEating() }  // 取到了:边嚼边等译文
            let translated = Self.translate(text)
            DispatchQueue.main.async {
                self.stopEating()
                self.isTranslating = false
                let msg = (translated?.isEmpty == false) ? translated! : "翻译失败了,主公"
                self.flashNotice(msg, accent: Self.translateAccent, duration: msg.count > 40 ? 10 : 7, force: true)  // 主公主动求译,免打扰也照弹
            }
        }
    }

    /// 取当前选中文本:先经辅助功能直读聚焦元素的 AXSelectedText(干净、不碰剪贴板),
    /// 取不到再回退"模拟 ⌘C 读剪贴板后还原"(覆盖不暴露 AXSelectedText 的应用)。仅读取,不改动选中内容。
    static func selectedText() -> String? {
        if let viaAX = selectedTextViaAccessibility(), !viaAX.isEmpty { return viaAX }
        return selectedTextViaCopy()
    }

    private static func selectedTextViaAccessibility() -> String? {
        let system = AXUIElementCreateSystemWide()
        guard let focused = copyAccessibilityAttribute(kAXFocusedUIElementAttribute as CFString, from: system),
              CFGetTypeID(focused) == AXUIElementGetTypeID() else { return nil }
        return accessibilityText(kAXSelectedTextAttribute as CFString, from: focused as! AXUIElement)
    }

    /// 模拟 ⌘C 复制选中文本:先存原剪贴板,合成按键,轮询 changeCount 等系统异步写入,读完即还原原内容。
    /// 必须在后台线程调用(含阻塞轮询);合成按键需辅助功能权限。
    private static func selectedTextViaCopy() -> String? {
        let pb = NSPasteboard.general
        let saved = pb.string(forType: .string)
        let before = pb.changeCount
        let src = CGEventSource(stateID: .combinedSessionState)
        let down = CGEvent(keyboardEventSource: src, virtualKey: CGKeyCode(kVK_ANSI_C), keyDown: true)
        down?.flags = .maskCommand
        let up = CGEvent(keyboardEventSource: src, virtualKey: CGKeyCode(kVK_ANSI_C), keyDown: false)
        up?.flags = .maskCommand
        down?.post(tap: .cghidEventTap)
        up?.post(tap: .cghidEventTap)
        var copied: String?
        for _ in 0..<40 {                 // 最多等 ~0.4s,等系统把选中内容写进剪贴板
            usleep(10_000)
            if pb.changeCount != before { copied = pb.string(forType: .string); break }
        }
        if pb.changeCount != before {     // 确实被我们改过才还原,免得污染主公的剪贴板
            pb.clearContents()
            if let saved { pb.setString(saved, forType: .string) }
        }
        return (copied?.isEmpty == false) ? copied : nil
    }

    /// 后台跑 claude(-p 非交互)翻译,返回纯译文;定位不到 CLI 或出错返回 nil。
    /// 复用投喂同一套候选(内置 cc 包装优先、官方 claude 兜底);cc 把 -p 透传给 claude,纯文本翻译不触发权限确认。
    static func translate(_ text: String) -> String? {
        let candidates = FeedTool.claude.fallbackPaths(relativeTo: Bundle.main.bundleURL)
        guard let tool = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
            return nil
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = ["-p", translatePrompt(for: text)]
        process.standardInput = FileHandle.nullDevice   // 不喂 stdin,免 claude 干等 3 秒
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()                   // 吞噪音,不污染译文
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return nil
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let raw = String(data: data, encoding: .utf8) ?? ""
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// 翻译指令:自动判向(中文→英文,其余→简体中文),只要译文不要解释。抽出便于 --translate-dryrun 核对。
    static func translatePrompt(for text: String) -> String {
        """
        Translate the following text. If it is mostly Chinese, translate into English; otherwise translate into Simplified Chinese. Output ONLY the translation, with no quotes, labels, or explanation.

        \(text)
        """
    }

    // MARK: 快捷键投喂:扑食动作
    // 从当前位置滑到鼠标处(主公选完文件,光标就在文件附近),张嘴吃一口,再滑回原位。
    // 窗口位移走 NSWindow animator;坐标用 NSEvent.mouseLocation(屏幕全局坐标,与 setFrameOrigin 同系)。
    func pounceToMouseAndEat(then onDone: @escaping () -> Void = {}) {
        guard let window else { eatBite(); onDone(); return }   // 没窗口(理论不会):原地吃后照常开终端
        guard !isPouncing else { eatBite(); onDone(); return }  // 扑食中再触发:原地嚼,不扰乱归位坐标
        isPouncing = true
        let home = window.frame.origin                     // 记住静止原位,吃完滑回
        let size = window.frame.size
        let mouse = NSEvent.mouseLocation
        let target = NSPoint(x: mouse.x - size.width / 2,  // 桌宠身体中心对准光标,顶部横幅不参与定位
                             y: mouse.y - Style.windowSize / 2)
        Self.log("扑食 mouse=\(NSStringFromPoint(mouse)) home=\(NSStringFromPoint(home)) target=\(NSStringFromPoint(target))")

        let duration = Settings.pounceDuration
        slideWindow(window, from: home, to: target, duration: duration) { [weak self] in
            self?.eatBite()                                // 到位:张嘴嚼一口
            let back = Timer(timeInterval: 0.9, repeats: false) { [weak self] _ in
                self?.slideWindow(window, from: target, to: home, duration: Settings.pounceDuration) {
                    self?.isPouncing = false               // 滑回到家,解除扑食锁
                    onDone()                               // 整段扑食结束才开终端,否则 Ghostty 弹出会盖住滑行
                }
            }
            RunLoop.main.add(back, forMode: .common)
        }
    }

    /// 用 .common 模式 Timer 逐帧把窗口从 from 移到 to(smoothstep 缓动),到位后回调 then。
    /// 不用 NSWindow animator 隐式动画——它对本例 borderless 窗口不产生可见位移(动画空跑、回调照常);
    /// 逐帧 setFrameOrigin 必定可见可控,与项目"咀嚼用 Timer 手动切帧"一脉相承。
    private func slideWindow(_ window: NSWindow, from: NSPoint, to: NSPoint,
                             duration: Double, then: @escaping () -> Void) {
        startRunningLegs()
        let steps = max(1, Int(duration * 60))             // 约 60fps
        let strideCount = max(2, Int(duration / 0.18))     // 每段滑行分成几步,用于上下起伏出"走过去"的节奏
        let bobHeight = Style.windowSize * 0.055
        var i = 0
        let timer = Timer(timeInterval: duration / Double(steps), repeats: true) { t in
            i += 1
            let p = Double(i) / Double(steps)
            let e = p * p * (3 - 2 * p)                     // smoothstep:缓入缓出
            let bob = sin(p * Double(strideCount) * .pi) * Double(bobHeight)
            window.setFrameOrigin(NSPoint(x: from.x + (to.x - from.x) * CGFloat(e),
                                          y: from.y + (to.y - from.y) * CGFloat(e) + CGFloat(bob)))
            if i >= steps {
                t.invalidate()
                self.stopRunningLegs()
                then()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
    }

    /// 切换图层内容,关闭隐式动画以求干脆的逐帧切换
    private func setFrame(_ image: CGImage?) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        iconLayer.contents = image
        CATransaction.commit()
    }

    /// 诊断日志(临时):追加写入 /tmp/claudepet.log,核对拖放/动画各环节是否触发
    static func log(_ message: String) {
        let line = message + "\n"
        let url = URL(fileURLWithPath: "/tmp/claudepet.log")
        if let fh = try? FileHandle(forWritingTo: url) {
            defer { try? fh.close() }
            fh.seekToEndOfFile()
            fh.write(Data(line.utf8))
        } else {
            try? line.write(to: url, atomically: true, encoding: .utf8)
        }
    }

    /// 标记为离屏快照模式(铺深色底),供 renderSnapshot 直接调用 draw 使用
    func prepareSnapshot(withBackground: Bool, mouthOpen: CGFloat = 0, eyeLook: CGVector = CGVector(dx: 0, dy: 0), eyeMode: EyeMode = .normal, runPhase: Int = 0) {
        snapshotBackground = withBackground
        snapshotMouthOpen = mouthOpen
        snapshotEyeLook = eyeLook
        snapshotEyeMode = eyeMode
        snapshotRunPhase = runPhase
    }

    // MARK: 绘制(仅离屏快照走此路径;运行时由图层显示)
    override func draw(_ dirtyRect: NSRect) {
        guard snapshotBackground else { return } // 运行时只允许 iconLayer 显示,避免背衬层留下第二份静止星芒
        if snapshotBackground, let ctx = NSGraphicsContext.current?.cgContext {
            ctx.setFillColor(NSColor(srgbRed: 0x1E / 255.0, green: 0x1E / 255.0, blue: 0x1E / 255.0, alpha: 1).cgColor)
            ctx.fill(bounds)
        }
        Self.starImage(size: bounds.size, mouthOpen: snapshotMouthOpen, eyeLook: snapshotEyeLook, eyeMode: snapshotEyeMode, runPhase: snapshotRunPhase).draw(in: bounds) // NSImage 自动处理坐标翻转
    }

    // MARK: 星星图标渲染
    /// 把 starArt 的方块字符逐个按 2×2 象限自绘成星芒:不走字体、直接填充矩形,
    /// 故无字体拼接缝隙,能严丝合缝还原终端里的样子;cell 取瘦高比例,呼应终端字符格。
    private static func starImage(size: CGSize, mouthOpen: CGFloat = 0, eyeLook: CGVector = CGVector(dx: 0, dy: 0), eyeMode: EyeMode = .normal, runPhase: Int = 0) -> NSImage {
        let image = NSImage(size: size)
        image.lockFocus()
        defer { image.unlockFocus() }
        guard let ctx = NSGraphicsContext.current?.cgContext else { return image }

        let rowCount = starArt.count
        let colCount = starArt.map(\.count).max() ?? 1
        let aspect: CGFloat = 2.0                       // cell 高/宽,模拟终端瘦高字符格
        let fill: CGFloat = 0.66                        // 网格占窗口比例:占大些更醒目,仍给外发光与边距留余量
        let cellW = min(size.width * fill / CGFloat(colCount),
                        size.height * fill / (CGFloat(rowCount) * aspect))
        let cellH = cellW * aspect
        let originX = (size.width - cellW * CGFloat(colCount)) / 2
        let originY = (size.height - cellH * CGFloat(rowCount)) / 2

        // 逐象限把 starArt 填成星芒主体
        func fillStar() {
            for (r, line) in starArt.enumerated() {
                for (c, ch) in line.enumerated() {
                    let q = quadrants(of: ch)
                    let x = originX + CGFloat(c) * cellW
                    let y = originY + CGFloat(rowCount - 1 - r) * cellH // y 轴向上,故行号倒置
                    let hw = cellW / 2, hh = cellH / 2
                    if q.0 { ctx.fill(CGRect(x: x,      y: y + hh, width: hw, height: hh)) } // 左上
                    if q.1 { ctx.fill(CGRect(x: x + hw, y: y + hh, width: hw, height: hh)) } // 右上
                    if q.2 { ctx.fill(CGRect(x: x,      y: y,      width: hw, height: hh)) } // 左下
                    if q.3 { ctx.fill(CGRect(x: x + hw, y: y,      width: hw, height: hh)) } // 右下
                }
            }
        }

        // 给星芒整体投一圈柔和的对比外发光,把形状从背景里托出来:
        // 用 transparency layer 把所有象限当成单一整体投影,内部拼缝不各自留影、只勾外轮廓,
        // 比硬描边更自然、不糊尖角(暗主色配白晕、亮主色配深晕);不依赖背景采样或权限。
        ctx.saveGState()
        ctx.setShadow(offset: .zero, blur: max(2.5, cellW * 0.55), color: outlineColor(for: Style.orange).cgColor)
        ctx.beginTransparencyLayer(auxiliaryInfo: nil)
        ctx.setFillColor(Style.orange.cgColor)
        fillStar()
        ctx.endTransparencyLayer()
        ctx.restoreGState()

        moveBuiltInEyeHoles(ctx, size: size, originX: originX, originY: originY,
                            cellW: cellW, cellH: cellH, look: eyeLook, mode: eyeMode)
        drawRunningLegsIfNeeded(ctx, size: size, originY: originY, cellW: cellW, cellH: cellH, phase: runPhase)

        // 进食态:在脸部中下方画一张暗色横口,开合幅度由 mouthOpen 决定(0 则无嘴)
        if mouthOpen > 0 {
            let mouthWidth = cellW * 3.2
            let mouthHeight = cellH * 0.95 * mouthOpen
            let mouthRect = CGRect(
                x: size.width / 2 - mouthWidth / 2,
                y: originY + cellH * 1.3 - mouthHeight / 2,    // 落在中行、眼睛下方
                width: mouthWidth,
                height: mouthHeight
            )
            ctx.setFillColor(Style.mouth.cgColor)              // 暗色实填,任何桌面背景下都醒目
            ctx.fill(mouthRect)
        }
        return image
    }

    /// 跑步态只改原本底部两条腿:先用背景橙补掉静止腿,再画成交替前后摆动的短腿。
    private static func drawRunningLegsIfNeeded(_ ctx: CGContext, size: CGSize,
                                                originY: CGFloat, cellW: CGFloat,
                                                cellH: CGFloat, phase: Int) {
        guard phase > 0 else { return }
        let legWidth = cellW * 0.5
        let longLegHeight = cellH * 0.56
        let shortLegHeight = cellH * 0.32
        let legY = originY - cellH * 0.03
        let baseCenters = [
            size.width / 2 - cellW * 1.05,
            size.width / 2 + cellW * 1.05,
        ]

        for x in baseCenters {
            ctx.clear(CGRect(x: x - legWidth * 1.1, y: legY - cellH * 0.08,
                             width: legWidth * 2.2, height: longLegHeight + cellH * 0.18))
        }

        ctx.setFillColor(Style.orange.cgColor)
        let offsets: [CGFloat] = phase % 2 == 1 ? [-cellW * 0.22, cellW * 0.16] : [cellW * 0.16, -cellW * 0.22]
        let heights: [CGFloat] = phase % 2 == 1 ? [longLegHeight, shortLegHeight] : [shortLegHeight, longLegHeight]
        for ((x, offset), height) in zip(zip(baseCenters, offsets), heights) {
            let foot = CGRect(
                x: x + offset - legWidth / 2,
                y: legY,
                width: legWidth,
                height: height
            )
            ctx.fill(foot)
        }
    }

    /// 复用原图里的两个深色竖向空位作为眼睛:先补回原空位(铺橙),再按眼形清出对应深色形状。
    /// normal=竖洞(随 look 偏移)、closed=水平细缝(眨眼/哈欠)、happy=上凸弯月(眯眼笑)。
    /// 没有新增眼睛素材,只是让原本两个空位变形/移动。
    private static func moveBuiltInEyeHoles(_ ctx: CGContext, size: CGSize,
                                            originX: CGFloat, originY: CGFloat,
                                            cellW: CGFloat, cellH: CGFloat,
                                            look: CGVector, mode: EyeMode) {
        let lookX = max(-1, min(1, look.dx))
        let lookY = max(-1, min(1, look.dy))
        let holeSize = CGSize(width: cellW * 0.56, height: cellH * 0.56)
        let patchSize = CGSize(width: cellW * 0.9, height: cellH * 0.62)
        let travelX = cellW * 0.18
        let travelY = cellH * 0.12
        let eyeY = originY + cellH * 2.22
        let centers = [
            CGPoint(x: size.width / 2 - cellW * 1.5, y: eyeY),
            CGPoint(x: size.width / 2 + cellW * 1.5, y: eyeY),
        ]

        // 先铺橙补回原本两个空位,后续再按眼形清出深色洞
        ctx.setFillColor(Style.orange.cgColor)
        for center in centers {
            let original = CGRect(
                x: center.x - patchSize.width / 2,
                y: center.y - patchSize.height / 2,
                width: patchSize.width,
                height: patchSize.height
            )
            ctx.fill(original)
        }

        switch mode {
        case .normal:
            // 睁眼:挖竖向空位,随鼠标方向在原位附近轻移
            for center in centers {
                let moved = CGRect(
                    x: center.x + travelX * lookX - holeSize.width / 2,
                    y: center.y + travelY * lookY - holeSize.height / 2,
                    width: holeSize.width,
                    height: holeSize.height
                )
                ctx.clear(moved)
            }
        case .closed:
            // 闭眼:挖一条水平细缝(眨眼/哈欠时用)。clear 混合模式可清出任意描边形状为透明
            ctx.setBlendMode(.clear)
            ctx.setLineCap(.round)
            ctx.setLineWidth(cellH * 0.16)
            for center in centers {
                let half = holeSize.width * 0.7
                ctx.beginPath()
                ctx.move(to: CGPoint(x: center.x - half, y: center.y))
                ctx.addLine(to: CGPoint(x: center.x + half, y: center.y))
                ctx.strokePath()
            }
            ctx.setBlendMode(.normal)
        case .happy:
            // 眯眼笑:挖两道上凸弯月(⌒ ⌒)。上半圆弧凸向 +y(屏幕上方),即开心的笑眼
            ctx.setBlendMode(.clear)
            ctx.setLineCap(.round)
            ctx.setLineWidth(cellH * 0.16)
            let r = holeSize.width * 0.8
            for center in centers {
                ctx.beginPath()
                ctx.addArc(center: CGPoint(x: center.x, y: center.y - r * 0.35), radius: r,
                           startAngle: .pi * 0.18, endAngle: .pi * 0.82, clockwise: false)
                ctx.strokePath()
            }
            ctx.setBlendMode(.normal)
        }
    }

    /// 轮廓光晕色:与主色形成稳定反差(暗主色配近白、亮主色配近黑暖),
    /// 作星芒外发光把形状从任何桌面背景里托出来,是"看不清"的核心兜底。
    private static func outlineColor(for color: NSColor) -> NSColor {
        let c = color.usingColorSpace(.sRGB) ?? color
        var brightness: CGFloat = 0
        c.getHue(nil, saturation: nil, brightness: &brightness, alpha: nil)
        return brightness < 0.55
            ? NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.95)          // 暗主色 → 近白描边
            : NSColor(srgbRed: 0.10, green: 0.08, blue: 0.05, alpha: 0.95) // 亮主色 → 近黑暖描边
    }

    /// 终端块元素字符 → 2×2 象限填充开关 (左上, 右上, 左下, 右下)
    private static func quadrants(of ch: Character) -> (Bool, Bool, Bool, Bool) {
        switch ch {
        case "█": return (true,  true,  true,  true)
        case "▌": return (true,  false, true,  false)
        case "▐": return (false, true,  false, true)
        case "▀": return (true,  true,  false, false)
        case "▄": return (false, false, true,  true)
        case "▘": return (true,  false, false, false)
        case "▝": return (false, true,  false, false)
        case "▖": return (false, false, true,  false)
        case "▗": return (false, false, false, true)
        case "▛": return (true,  true,  true,  false)
        case "▜": return (true,  true,  false, true)
        case "▙": return (true,  false, true,  true)
        case "▟": return (false, true,  true,  true)
        default:  return (false, false, false, false)
        }
    }

    // MARK: 右键菜单
    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = NSMenu()
        let title = NSMenuItem(title: "Claude 桌面宠物", action: nil, keyEquivalent: "")
        title.isEnabled = false
        menu.addItem(title)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "设置...", action: #selector(AppDelegate.showSettings(_:)), keyEquivalent: ","))
        menu.addItem(NSMenuItem(title: "远程遥控(Telegram / 飞书)…", action: #selector(AppDelegate.showRemoteControl(_:)), keyEquivalent: ""))
        let help = NSMenuItem(title: "使用说明…", action: #selector(showHelp(_:)), keyEquivalent: "")
        help.target = self
        menu.addItem(help)
        menu.addItem(.separator())
        let askClaude = NSMenuItem(title: "问 Claude…", action: #selector(askClaudeMenu(_:)), keyEquivalent: "")
        askClaude.target = self
        menu.addItem(askClaude)
        let askCodex = NSMenuItem(title: "问 Codex…", action: #selector(askCodexMenu(_:)), keyEquivalent: "")
        askCodex.target = self
        menu.addItem(askCodex)
        menu.addItem(.separator())
        let testWeChat = NSMenuItem(title: "测试微信提示", action: #selector(testWeChatNotificationHint(_:)), keyEquivalent: "")
        testWeChat.target = self
        menu.addItem(testWeChat)
        let testLark = NSMenuItem(title: "测试飞书提示", action: #selector(testLarkNotificationHint(_:)), keyEquivalent: "")
        testLark.target = self
        menu.addItem(testLark)
        let testTaskDone = NSMenuItem(title: "测试任务完成提示", action: #selector(testTaskDoneHint(_:)), keyEquivalent: "")
        testTaskDone.target = self
        menu.addItem(testTaskDone)
        let dumpItem = NSMenuItem(title: "导出微信探测详情", action: #selector(exportWeChatDiagnostics(_:)), keyEquivalent: "")
        dumpItem.target = self
        menu.addItem(dumpItem)
        menu.addItem(NSMenuItem(title: "退出", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        return menu
    }

    @objc private func askClaudeMenu(_ sender: Any?) { promptAndFeed(tool: .claude) }
    @objc private func askCodexMenu(_ sender: Any?) { promptAndFeed(tool: .codex) }

    /// 右键"使用说明…":弹一个可滚动的只读窗,列齐全部功能与快捷键。
    /// 内容与仓库 README 同源,人工保持一致(改功能时两处一并改)。
    @objc private func showHelp(_ sender: Any?) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "ClaudePet 使用说明"
        alert.addButton(withTitle: "知道了")
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 380, height: 440))
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        let textView = NSTextView(frame: scroll.bounds)
        textView.isEditable = false
        textView.isSelectable = true
        textView.drawsBackground = false
        textView.textContainerInset = NSSize(width: 10, height: 8)
        textView.font = .systemFont(ofSize: 12)
        textView.string = Self.helpText
        scroll.documentView = textView
        alert.accessoryView = scroll
        alert.runModal()
    }

    /// 使用说明全文(右键"使用说明…"展示)。与仓库 README 内容对齐。
    private static let helpText = """
    ClaudePet 桌面宠物 · 使用说明

    — 全局快捷键(任何应用里都生效) —
      ⌥⌘C   Finder 选中的文件/目录 → 喂给 Claude 分析
      ⌥⌘X   Finder 选中的文件/目录 → 喂给 Codex 分析
      ⌥⌘V   剪贴板里的文字 → 喂给 Claude
      ⌥⌘T   翻译选中的文字(中↔英),头顶气泡显示

    — 投喂(只读,绝不删改文件) —
      • 把文件/目录拖到桌宠身上 → 喂给 Claude
      • 双击桌宠,或右键"问 Claude…/问 Codex…" → 弹框打字或贴报错
      • 投喂时桌宠会扑到鼠标处张嘴嚼一口,随后在终端开会话
      • 优先用 cc/cx(官方命令+跳过确认);首次启动自动写进 ~/.zshrc,新开终端即用

    — 鼠标互动 —
      • 悬停 → 眯眼笑、鼓起来、发光
      • 单击 → 吃一口    双击 → 问一句
      • 按住身体拖动 → 挪到屏幕别处
      • 右键 → 菜单(设置 / 远程遥控 / 问一句 / 使用说明 / 测试 / 退出)

    — 陪跑(Claude Code · Codex,需接入通知钩子) —
      • 开工进专注态、等你确认时横幅催点头、收工报喜
      • 右上角角标:正在执行显「跑N」、Claude 停下等你回答显「等N」(琥珀);答完一轮即消
      • 报错/网络重试那轮也算收工(钩子接 StopFailure);客户端崩了按进程存活清角标
      • 点"报喜/等确认"横幅 → 把终端唤回前台(或用访达打开目录)

    — 远程遥控(Telegram / 飞书,默认关) —
      • 手机给 bot 发话 → 桌宠在本机非交互跑 cc/cx,干完回话回传聊天(带实时进度)
      • cc/cx 各占一个独立 bot/应用、各记上下文;聊天里 /cd · /pwd · /new · /help
      • 收到指令/答完一轮会闪横幅,远程有动静在电脑前也看得见
      • 注意:跳过权限确认、真能改文件跑命令,务必设白名单只给自己用
      • 飞书私聊直接发、群里需 @机器人(仅国内版 open.feishu.cn 支持长连接)
      • 右键"远程遥控(Telegram / 飞书)…"填 token/应用凭证与白名单后启用

    — 任务监控(默认关) —
      • 把远程遥控每轮"问题→答案"连同耗时/花费落盘,并起本地仪表盘
      • 开启后浏览器访问 http://127.0.0.1:8722 看记录(端口可在设置改)
      • 只覆盖远程两条链路;本机投喂交给终端、拿不到答案故不记

    — 作息脾气 —
      • 久没人理会蔫(摸一下/喂一下回血)
      • 久坐提醒(间隔可调)、深夜多打哈欠

    — 通知横幅 —
      • 微信(绿)/飞书(蓝)未读、任务完成(橙)
      • 免打扰:一键静音所有被动提示(翻译/测试不受影响)

    — 设置(右键"设置...") —
      任务监控 · 权限(完全磁盘访问/辅助功能,看状态+一键去开)· 移动速度 ·
      颜色/自动配色 · 划词翻译 · 陪跑各项 · 作息脾气 ·
      通知/免打扰 · 停靠角 · 开机自启

    接入陪跑通知钩子、远程遥控启用步骤、构建运行等,详见仓库 README。
    """

    @objc private func testWeChatNotificationHint(_ sender: Any?) {
        showWeChatNotificationHint(message: "微信来消息了", force: true)   // 主动测试:免打扰也照弹
    }

    @objc private func testLarkNotificationHint(_ sender: Any?) {
        flashNotice("飞书来消息了", accent: Self.larkAccent, force: true)
    }

    @objc private func testTaskDoneHint(_ sender: Any?) {
        // 演示带任务简介的自适应横幅:长任务会自动换行加高;带家目录,便于当场点横幅验证回现场
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        showTaskDoneHint(message: "Claude · 把登录模块重构成 async/await 并补全单元测试和错误处理", actionCwd: home, force: true)
    }

    // 临时诊断:把 Dock 与微信辅助功能树的真实字段 dump 到 /tmp/claudepet.log,取证后移除
    @objc private func exportWeChatDiagnostics(_ sender: Any?) {
        Self.dumpWeChatAccessibilityTree()
        showWeChatNotificationHint(message: "已导出探测详情", force: true)
    }

    // MARK: 拖放投喂:接住拖入的文件/目录,唤起 claude code 分析
    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        Self.log("draggingEntered canAccept=\(canAcceptFiles(sender))")
        guard canAcceptFiles(sender) else { return [] }
        setFeedGlow(true) // 高亮提示“可投喂”
        startEating()      // 张嘴咀嚼,等着被投喂
        return .copy
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        canAcceptFiles(sender) ? .copy : []  // 持续告知系统可接收,维持拖放会话
    }

    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
        Self.log("prepareForDragOperation")
        return canAcceptFiles(sender) // 返回 true 才会续到 performDragOperation
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        Self.log("draggingExited")
        setFeedGlow(false)
        stopEating()       // 没投喂就走开?闭嘴
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        Self.log("performDragOperation")
        setFeedGlow(false)
        stopEating()       // 吃下,闭嘴
        let urls = (sender.draggingPasteboard.readObjects(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]
        ) as? [URL]) ?? []
        guard !urls.isEmpty else { return false }
        urls.forEach { Self.analyze($0, with: .claude) } // 拖放固定走 claude;每个文件各开一个会话
        return true
    }

    /// 拖入/悬停时点亮橙色光晕,熄灭时回落到常驻淡阴影;借图层阴影实现,随 transform 动画一起动,不与呼吸缩放打架
    private func setFeedGlow(_ on: Bool) {
        if on {
            iconLayer.shadowColor = Style.orange.cgColor
            iconLayer.shadowRadius = 12
            iconLayer.shadowOffset = .zero
            iconLayer.shadowOpacity = 0.9
        } else {
            applyBaseShadow()
        }
    }

    /// 常驻淡落地阴影:替代窗口级 hasShadow(后者在图层 transform 动画时会残留出"第二个"重影)。
    /// 图层阴影跟随图层一起平移/旋转/缩放,跳跳摇摇都不留残影。
    private func applyBaseShadow() {
        iconLayer.shadowColor = NSColor.black.cgColor
        iconLayer.shadowRadius = 5
        iconLayer.shadowOffset = CGSize(width: 0, height: -3) // 影子落在正下方(图层 y 向上,故取负)
        iconLayer.shadowOpacity = 0.35
    }

    private func canAcceptFiles(_ sender: NSDraggingInfo) -> Bool {
        sender.draggingPasteboard.canReadObject(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]
        )
    }

    // MARK: 唤起分析工具(claude / codex)
    /// 在文件所在目录用 Ghostty 开终端,启动交互式分析工具(tool)并预填指令;
    /// 经临时 .command 脚本承载命令,无需任何额外权限。
    static func analyze(_ url: URL, with tool: FeedTool) {
        runFeedScript(feedScript(for: url, tool: tool))
    }

    /// 投喂一段文字(非文件):在主公家目录起会话,prompt 即这段文字。给"双击问一句""⌥⌘V 喂剪贴板"用。
    /// 复用同一套脚本与 cc/cx 候选,跳过权限确认;只读文本,绝不碰任何文件。
    static func analyzeText(_ text: String, with tool: FeedTool) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { NSSound.beep(); return }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        runFeedScript(feedScript(workingDir: home, prompt: trimmed, tool: tool))
    }

    /// 把投喂脚本写到临时 .command 并用终端跑起来(文件投喂与文字投喂共用此收尾)。
    private static func runFeedScript(_ content: String) {
        let scriptURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("claudepet-feed-\(UUID().uuidString).command")
        do {
            try content.write(to: scriptURL, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)
            try openTerminal(running: scriptURL)
        } catch {
            NSSound.beep() // 失败给个声响,不静默吞掉
        }
    }

    /// 取 Finder 当前所有选中项的 POSIX 路径;无选中返回空数组。
    /// 走 osascript 子进程(与 analyze 起外部命令一脉相承),首次会触发"控制 Finder"的自动化授权。
    /// 仅读取选中信息,绝不移动或删除文件——"吃"只是动画与触发分析,文件留在原位。
    static func finderSelectionPaths() -> [String] {
        let script = """
        tell application "Finder"
            set out to ""
            repeat with anItem in (selection as alias list)
                set out to out & (POSIX path of anItem) & linefeed
            end repeat
            return out
        end tell
        """
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", script]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()                   // 吞掉报错,避免污染输出
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return []
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let raw = String(data: data, encoding: .utf8) ?? ""
        return raw.split(whereSeparator: \.isNewline).map(String.init).filter { !$0.isEmpty }
    }

    /// 优先用 Ghostty 执行脚本(`ghostty -e <脚本>`,在新窗口里跑);
    /// Ghostty 不在时回退系统默认(Terminal 执行 .command),保证功能不哑火。
    private static func openTerminal(running scriptURL: URL) throws {
        let ghostty = "/Applications/Ghostty.app/Contents/MacOS/ghostty"
        guard FileManager.default.isExecutableFile(atPath: ghostty) else {
            NSWorkspace.shared.open(scriptURL) // 兜底:交给默认终端
            return
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: ghostty)
        process.arguments = ["-e", scriptURL.path]
        try process.run()
    }

    /// 生成投喂脚本:cd 到目标目录,定位 tool 对应命令,预填“分析这个文件/目录”后进入交互会话。
    /// 单独拆出便于命令行 --feed-dryrun 核对转义,也是唯一的脚本来源。
    static func feedScript(for url: URL, tool: FeedTool = .claude) -> String {
        var isDirectory: ObjCBool = false
        FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
        let workingDir = isDirectory.boolValue ? url.path : url.deletingLastPathComponent().path
        let name = url.lastPathComponent
        let prompt = isDirectory.boolValue ? "请分析这个目录:\(name)" : "请分析这个文件:\(name)"
        return feedScript(workingDir: workingDir, prompt: prompt, tool: tool)
    }

    /// 通用投喂脚本:cd 到 workingDir,定位 tool 命令,预填 prompt 后进入交互会话。
    /// 文件投喂(feedScript(for:))与文字投喂(analyzeText)共用;单独拆出便于 --feed-dryrun/--ask-dryrun 核对转义。
    static func feedScript(workingDir: String, prompt: String, tool: FeedTool = .claude) -> String {
        let toolCandidates = (tool.commands + tool.fallbackPaths(relativeTo: Bundle.main.bundleURL))
            .map(shellQuoted)
            .joined(separator: " ")
        // 交互 shell 通常已含 Homebrew 路径,再查常见绝对路径;缺失时给可见提示,避免执行不存在的文件。
        return """
        #!/bin/zsh
        # ClaudePet feed script v4: 投喂先用 cc/cx 包装(官方命令+跳过确认),没有再退官方 claude/codex
        cd \(shellQuoted(workingDir)) || exit 1
        TOOL=""
        for candidate in \(toolCandidates); do
          if [[ "$candidate" == /* ]]; then
            [[ -x "$candidate" ]] && TOOL="$candidate" && break
          elif TOOL="$(command -v "$candidate" 2>/dev/null)"; then
            break
          else
            TOOL=""
          fi
        done
        if [[ -z "$TOOL" ]]; then
          echo "找不到 \(tool.label) CLI,请先安装或把它加入 PATH。"
          exit 127
        fi
        "$TOOL" \(shellQuoted(prompt))
        rc=$?
        echo
        if [[ $rc -ne 0 ]]; then
          echo "[ClaudePet] 工具异常退出(状态码 $rc),上方若有报错请据此排查。"
        fi
        echo "[ClaudePet] 会话结束,按回车键关闭此窗口…"
        read < /dev/tty
        """
    }

    /// 单引号包裹做 shell 转义,内部单引号以 '\'' 收尾再续,杜绝路径里的空格与特殊字符作怪
    private static func shellQuoted(_ raw: String) -> String {
        "'" + raw.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

// MARK: - 投喂目标 CLI
/// 投喂时在终端里跑哪个分析工具。claude 与 cx 共用同一套脚本,仅命令候选与兜底路径不同。
enum FeedTool {
    case claude
    case codex

    /// PATH 里先试的命令名:cc/cx 是主公"官方命令 + 跳过确认参数"的别名。但投喂脚本是非交互 shell、
    /// 取不到 alias,这一步通常落空,真正生效的是 fallbackPaths 里的同名内置包装脚本。
    var commands: [String] {
        switch self {
        case .claude: return []
        case .codex:  return []
        }
    }

    /// 绝对路径兜底,按优先级:先桌宠内置的 cc/cx 包装脚本(= 官方命令 + 跳过确认参数),
    /// 没有再退到官方 claude/codex —— 即主公要的"先 cc/cx,没有再 claude/codex"。
    func fallbackPaths(relativeTo appBundleURL: URL) -> [String] {
        let resources = appBundleURL
            .appendingPathComponent("Contents")
            .appendingPathComponent("Resources")
        switch self {
        case .claude:
            return [resources.appendingPathComponent("cc").path,
                    "/opt/homebrew/bin/claude", "/usr/local/bin/claude"]
        case .codex:
            return [resources.appendingPathComponent("cx").path,
                    "/opt/homebrew/bin/codex", "/usr/local/bin/codex"]
        }
    }

    /// 日志/提示用名:体现"包装命令优先、官方命令兜底"
    var label: String {
        switch self {
        case .claude: return "cc/claude"
        case .codex:  return "cx/codex"
        }
    }
}

// MARK: - 全局热键
// 用 Carbon RegisterEventHotKey 注册系统级快捷键:后台附件应用即可全局生效,免辅助功能权限。
// 中心化设计:只装【一个】application 级事件处理器,按事件携带的 hotKeyID 分发到对应回调——
// 若每个热键各装一个 handler,会因 Carbon 事件传播链相互抢占(先返回 noErr 者吃掉事件),另一个就哑了。
enum GlobalHotKey {
    private static var actions: [UInt32: () -> Void] = [:]   // hotKeyID.id → 回调
    private static var installed = false

    /// 注册一个全局热键;keyCode 兼作 hotKeyID(各键互异)。注册失败返回 false。
    @discardableResult
    static func register(keyCode: UInt32, modifiers: UInt32, action: @escaping () -> Void) -> Bool {
        installHandler()
        actions[keyCode] = action
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(
            keyCode, modifiers,
            EventHotKeyID(signature: OSType(0x4350_4554), id: keyCode),   // 'CPET' + keyCode
            GetApplicationEventTarget(), 0, &ref
        )
        if status != noErr { actions[keyCode] = nil; return false }
        return true
    }

    /// 全局唯一处理器:取出事件里的 hotKeyID,查表派发。app 退出由系统回收热键,无需手动注销。
    private static func installHandler() {
        guard !installed else { return }
        installed = true
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                 eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            guard let event else { return OSStatus(eventNotHandledErr) }
            var id = EventHotKeyID()
            let err = GetEventParameter(event, EventParamName(kEventParamDirectObject),
                                        EventParamType(typeEventHotKeyID), nil,
                                        MemoryLayout<EventHotKeyID>.size, nil, &id)
            guard err == noErr, let action = GlobalHotKey.actions[id.id] else {
                return OSStatus(eventNotHandledErr)
            }
            action()
            return noErr
        }, 1, &spec, nil, nil)
    }

    /// 快捷键触发:取 Finder 选中项 → 回主线程"扑过去吃一口" → 扑食整段跑完才用 tool 唤起分析。
    /// osascript 取选中项可能阻塞,放后台线程;UI 与起进程统一回主线程。
    static func feedFromFinder(into petView: PetView?, with tool: FeedTool) {
        PetView.log("热键触发 → \(tool.label)")
        DispatchQueue.global(qos: .userInitiated).async {
            let paths = PetView.finderSelectionPaths()
            PetView.log("Finder 选中 \(paths.count) 项")
            DispatchQueue.main.async {
                guard !paths.isEmpty else { NSSound.beep(); return }   // 没选中:响一声示意
                // 先扑过去吃,扑食整段(滑过去→嚼→滑回)跑完才开终端——否则终端立刻弹出会盖住滑行
                let analyze = { paths.forEach { PetView.analyze(URL(fileURLWithPath: $0), with: tool) } }
                if let petView {
                    petView.pounceToMouseAndEat(then: analyze)
                } else {
                    analyze()                                          // 没视图(理论不会):直接开终端
                }
            }
        }
    }

    /// ⌥⌘V:把剪贴板里的文字喂给 tool。直接读 NSPasteboard(不模拟按键),无需辅助功能权限;
    /// 有视图则扑到鼠标处嚼一口再开会话,与 Finder 投喂观感一致。
    static func feedClipboard(into petView: PetView?, with tool: FeedTool) {
        let text = NSPasteboard.general.string(forType: .string) ?? ""
        PetView.log("热键触发 ⌥⌘V → \(tool.label) 剪贴板 \(text.count) 字")
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { NSSound.beep(); return }
        if let petView {
            petView.pounceToMouseAndEat { PetView.analyzeText(text, with: tool) }
        } else {
            PetView.analyzeText(text, with: tool)
        }
    }
}

// MARK: - 应用代理
@MainActor
final class SettingsWindowController: NSWindowController, NSWindowDelegate {
    private let valueLabel = NSTextField(labelWithString: "")
    private let colorTitle = NSTextField(labelWithString: "手动颜色")
    private let colorWell = NSColorWell(frame: .zero)
    private let autoAdaptButton = NSButton(checkboxWithTitle: "自动适应环境", target: nil, action: nil)
    private let weChatNotificationsButton = NSButton(checkboxWithTitle: "接收微信", target: nil, action: nil)
    private let larkNotificationsButton = NSButton(checkboxWithTitle: "接收飞书", target: nil, action: nil)
    private let taskDoneNotificationsButton = NSButton(checkboxWithTitle: "任务完成提示", target: nil, action: nil)
    private let focusOnStartButton = NSButton(checkboxWithTitle: "开工进专注态", target: nil, action: nil)
    private let notifyOnWaitingButton = NSButton(checkboxWithTitle: "等我确认时提醒", target: nil, action: nil)
    private let moodDecayButton = NSButton(checkboxWithTitle: "会饿会蔫", target: nil, action: nil)
    private let sedentaryButton = NSButton(checkboxWithTitle: "久坐提醒", target: nil, action: nil)
    private let sedentaryStepper = NSStepper()
    private let sedentaryLabel = NSTextField(labelWithString: "")
    private let nightDrowsyButton = NSButton(checkboxWithTitle: "深夜犯困", target: nil, action: nil)
    private let dockCornerPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let launchAtLoginButton = NSButton(checkboxWithTitle: "开机自启", target: nil, action: nil)
    private let translateButton = NSButton(checkboxWithTitle: "启用(选中文字按 ⌥⌘T)", target: nil, action: nil)
    private let doNotDisturbButton = NSButton(checkboxWithTitle: "免打扰(静音提示)", target: nil, action: nil)
    private let showSessionBadgeButton = NSButton(checkboxWithTitle: "显示会话角标(绿点跑·琥珀点等)", target: nil, action: nil)
    private let monitorButton = NSButton(checkboxWithTitle: "挂载监控系统(记录远程任务并起本地页面)", target: nil, action: nil)
    private let monitorPortField = NSTextField(string: "")
    private let monitorNoteLabel = NSTextField(labelWithString: "")
    private let fdaStatusLabel = NSTextField(labelWithString: "")
    private let axStatusLabel = NSTextField(labelWithString: "")
    private let slider = NSSlider(value: Settings.pounceDuration,
                                  minValue: Settings.minPounceDuration,
                                  maxValue: Settings.maxPounceDuration,
                                  target: nil,
                                  action: nil)

    init() {
        let content = NSView(frame: NSRect(x: 0, y: 0, width: 360, height: 952))
        let window = NSWindow(
            contentRect: content.frame,
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "ClaudePet 设置"
        window.isReleasedWhenClosed = false
        window.contentView = content
        super.init(window: window)
        window.delegate = self
        buildContent(in: content)
        updateValueLabel()
        colorWell.color = Settings.petColor
        updateColorControls()
        updateWeChatControls()
        updateCompanionControls()
        updateBehaviorControls()
        updateWindowControls()
        updateTranslateControls()
        updatePermissionControls()
        updateMonitorControls()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("不支持 Interface Builder 加载") }

    private func buildContent(in content: NSView) {
        // 分组小标题:加粗次级色,统一各组的视觉分隔
        func section(_ text: String, y: CGFloat) {
            let label = NSTextField(labelWithString: text)
            label.font = .systemFont(ofSize: 13, weight: .bold)
            label.textColor = .secondaryLabelColor
            label.frame = NSRect(x: 24, y: y, width: 312, height: 18)
            content.addSubview(label)
        }

        // —— 任务监控(顶部新增组:加高窗口腾出空间,不动既有控件 y 坐标)——
        section("任务监控", y: 920)
        monitorButton.target = self
        monitorButton.action = #selector(monitorChanged(_:))
        monitorButton.frame = NSRect(x: 24, y: 892, width: 300, height: 24)
        content.addSubview(monitorButton)
        let openMonitorButton = NSButton(title: "打开页面", target: self, action: #selector(openMonitor(_:)))
        openMonitorButton.bezelStyle = .rounded
        openMonitorButton.frame = NSRect(x: 250, y: 889, width: 86, height: 26)
        content.addSubview(openMonitorButton)
        let portTitle = NSTextField(labelWithString: "端口")
        portTitle.frame = NSRect(x: 24, y: 862, width: 40, height: 22)
        content.addSubview(portTitle)
        monitorPortField.target = self
        monitorPortField.action = #selector(monitorPortChanged(_:))
        monitorPortField.alignment = .center
        monitorPortField.frame = NSRect(x: 66, y: 860, width: 64, height: 24)
        content.addSubview(monitorPortField)
        monitorNoteLabel.font = .systemFont(ofSize: 11)
        monitorNoteLabel.textColor = .secondaryLabelColor
        monitorNoteLabel.lineBreakMode = .byTruncatingTail
        monitorNoteLabel.frame = NSRect(x: 140, y: 862, width: 196, height: 22)
        content.addSubview(monitorNoteLabel)

        // —— 权限(系统授权需手动开;app 无法自授权,这里只显示状态 + 一键带你去开)——
        section("权限", y: 828)
        let fdaName = NSTextField(labelWithString: "完全磁盘访问")
        fdaName.frame = NSRect(x: 24, y: 800, width: 120, height: 22)
        content.addSubview(fdaName)
        fdaStatusLabel.alignment = .right
        fdaStatusLabel.frame = NSRect(x: 146, y: 800, width: 96, height: 22)
        content.addSubview(fdaStatusLabel)
        let fdaButton = NSButton(title: "去开启…", target: self, action: #selector(openFullDiskAccess(_:)))
        fdaButton.bezelStyle = .rounded
        fdaButton.frame = NSRect(x: 250, y: 797, width: 86, height: 26)
        content.addSubview(fdaButton)

        let axName = NSTextField(labelWithString: "辅助功能")
        axName.frame = NSRect(x: 24, y: 772, width: 120, height: 22)
        content.addSubview(axName)
        axStatusLabel.alignment = .right
        axStatusLabel.frame = NSRect(x: 146, y: 772, width: 96, height: 22)
        content.addSubview(axStatusLabel)
        let axButton = NSButton(title: "去开启…", target: self, action: #selector(openAccessibilitySettings(_:)))
        axButton.bezelStyle = .rounded
        axButton.frame = NSRect(x: 250, y: 769, width: 86, height: 26)
        content.addSubview(axButton)

        let autoNote = NSTextField(labelWithString: "自动化(控制 Finder/终端)首次用到时弹窗,点允许即可")
        autoNote.font = .systemFont(ofSize: 11)
        autoNote.textColor = .secondaryLabelColor
        autoNote.frame = NSRect(x: 24, y: 748, width: 312, height: 16)
        content.addSubview(autoNote)

        // —— 划词翻译 ——
        section("划词翻译", y: 716)
        translateButton.target = self
        translateButton.action = #selector(translateChanged(_:))
        translateButton.frame = NSRect(x: 24, y: 688, width: 300, height: 24)
        content.addSubview(translateButton)

        // —— 互动 ——
        section("互动", y: 648)
        let speedTitle = NSTextField(labelWithString: "移动速度")
        speedTitle.frame = NSRect(x: 24, y: 618, width: 120, height: 22)
        content.addSubview(speedTitle)
        valueLabel.alignment = .right
        valueLabel.frame = NSRect(x: 200, y: 618, width: 136, height: 22)
        content.addSubview(valueLabel)

        slider.target = self
        slider.action = #selector(sliderChanged(_:))
        slider.numberOfTickMarks = 6
        slider.allowsTickMarkValuesOnly = false
        slider.frame = NSRect(x: 24, y: 592, width: 312, height: 24)
        content.addSubview(slider)

        let fast = NSTextField(labelWithString: "快")
        fast.textColor = .secondaryLabelColor
        fast.frame = NSRect(x: 24, y: 570, width: 40, height: 18)
        content.addSubview(fast)
        let slow = NSTextField(labelWithString: "慢")
        slow.textColor = .secondaryLabelColor
        slow.alignment = .right
        slow.frame = NSRect(x: 296, y: 570, width: 40, height: 18)
        content.addSubview(slow)

        colorTitle.font = .systemFont(ofSize: 13, weight: .regular)
        colorTitle.frame = NSRect(x: 24, y: 540, width: 120, height: 22)
        content.addSubview(colorTitle)
        colorWell.target = self
        colorWell.action = #selector(colorChanged(_:))
        colorWell.frame = NSRect(x: 288, y: 536, width: 48, height: 30)
        content.addSubview(colorWell)

        autoAdaptButton.target = self
        autoAdaptButton.action = #selector(autoAdaptChanged(_:))
        autoAdaptButton.frame = NSRect(x: 24, y: 506, width: 220, height: 24)
        content.addSubview(autoAdaptButton)

        // —— 陪跑(Claude Code / Codex)——
        section("陪跑(Claude Code / Codex)", y: 472)
        focusOnStartButton.target = self
        focusOnStartButton.action = #selector(focusOnStartChanged(_:))
        focusOnStartButton.frame = NSRect(x: 24, y: 444, width: 220, height: 24)
        content.addSubview(focusOnStartButton)
        notifyOnWaitingButton.target = self
        notifyOnWaitingButton.action = #selector(notifyOnWaitingChanged(_:))
        notifyOnWaitingButton.frame = NSRect(x: 24, y: 418, width: 240, height: 24)
        content.addSubview(notifyOnWaitingButton)
        taskDoneNotificationsButton.target = self
        taskDoneNotificationsButton.action = #selector(taskDoneNotificationsChanged(_:))
        taskDoneNotificationsButton.frame = NSRect(x: 24, y: 392, width: 220, height: 24)
        content.addSubview(taskDoneNotificationsButton)
        showSessionBadgeButton.target = self
        showSessionBadgeButton.action = #selector(showSessionBadgeChanged(_:))
        showSessionBadgeButton.frame = NSRect(x: 24, y: 366, width: 260, height: 24)
        content.addSubview(showSessionBadgeButton)

        // —— 作息脾气 ——
        section("作息脾气", y: 332)
        moodDecayButton.target = self
        moodDecayButton.action = #selector(moodDecayChanged(_:))
        moodDecayButton.frame = NSRect(x: 24, y: 304, width: 160, height: 24)
        content.addSubview(moodDecayButton)

        sedentaryButton.target = self
        sedentaryButton.action = #selector(sedentaryChanged(_:))
        sedentaryButton.frame = NSRect(x: 24, y: 278, width: 110, height: 24)
        content.addSubview(sedentaryButton)
        sedentaryStepper.target = self
        sedentaryStepper.action = #selector(sedentaryStepperChanged(_:))
        sedentaryStepper.minValue = Double(Settings.minSedentaryMinutes)
        sedentaryStepper.maxValue = Double(Settings.maxSedentaryMinutes)
        sedentaryStepper.increment = 5
        sedentaryStepper.integerValue = Settings.petSedentaryMinutes
        sedentaryStepper.frame = NSRect(x: 138, y: 276, width: 20, height: 28)
        content.addSubview(sedentaryStepper)
        sedentaryLabel.textColor = .secondaryLabelColor
        sedentaryLabel.frame = NSRect(x: 166, y: 278, width: 170, height: 22)
        content.addSubview(sedentaryLabel)

        nightDrowsyButton.target = self
        nightDrowsyButton.action = #selector(nightDrowsyChanged(_:))
        nightDrowsyButton.frame = NSRect(x: 24, y: 252, width: 160, height: 24)
        content.addSubview(nightDrowsyButton)

        // —— 通知 ——
        section("通知", y: 218)
        weChatNotificationsButton.target = self
        weChatNotificationsButton.action = #selector(weChatNotificationsChanged(_:))
        weChatNotificationsButton.frame = NSRect(x: 24, y: 190, width: 130, height: 24)
        content.addSubview(weChatNotificationsButton)
        larkNotificationsButton.target = self
        larkNotificationsButton.action = #selector(larkNotificationsChanged(_:))
        larkNotificationsButton.frame = NSRect(x: 168, y: 190, width: 130, height: 24)
        content.addSubview(larkNotificationsButton)
        doNotDisturbButton.target = self
        doNotDisturbButton.action = #selector(doNotDisturbChanged(_:))
        doNotDisturbButton.frame = NSRect(x: 24, y: 164, width: 260, height: 24)
        content.addSubview(doNotDisturbButton)

        // —— 窗口 ——
        section("窗口", y: 130)
        let dockTitle = NSTextField(labelWithString: "停靠")
        dockTitle.frame = NSRect(x: 24, y: 100, width: 50, height: 22)
        content.addSubview(dockTitle)
        dockCornerPopup.target = self
        dockCornerPopup.action = #selector(dockCornerChanged(_:))
        dockCornerPopup.addItems(withTitles: DockCorner.allCases.map { $0.title })
        dockCornerPopup.frame = NSRect(x: 80, y: 96, width: 150, height: 26)
        content.addSubview(dockCornerPopup)

        launchAtLoginButton.target = self
        launchAtLoginButton.action = #selector(launchAtLoginChanged(_:))
        launchAtLoginButton.frame = NSRect(x: 24, y: 66, width: 200, height: 24)
        content.addSubview(launchAtLoginButton)

        let close = NSButton(title: "关闭", target: self, action: #selector(closeWindow(_:)))
        close.bezelStyle = .rounded
        close.frame = NSRect(x: 258, y: 18, width: 78, height: 28)
        content.addSubview(close)
    }

    @objc private func sliderChanged(_ sender: NSSlider) {
        Settings.pounceDuration = sender.doubleValue
        updateValueLabel()
    }

    @objc private func colorChanged(_ sender: NSColorWell) {
        Settings.petColor = sender.color
        NotificationCenter.default.post(name: .petColorDidChange, object: nil)
    }

    @objc private func autoAdaptChanged(_ sender: NSButton) {
        Settings.autoAdaptColor = sender.state == .on
        updateColorControls()
        NotificationCenter.default.post(name: .autoAdaptColorDidChange, object: nil)
    }

    @objc private func weChatNotificationsChanged(_ sender: NSButton) {
        Settings.setIMNotificationsEnabled("receiveWeChatNotifications", sender.state == .on)
        updateWeChatControls()
        if sender.state == .on {
            _ = PetView.accessibilityTrusted(prompt: true)
        }
        NotificationCenter.default.post(name: .weChatNotificationsDidChange, object: nil)
    }

    @objc private func larkNotificationsChanged(_ sender: NSButton) {
        Settings.setIMNotificationsEnabled("receiveLarkNotifications", sender.state == .on)
        updateWeChatControls()
        if sender.state == .on {
            _ = PetView.accessibilityTrusted(prompt: true)
        }
        NotificationCenter.default.post(name: .weChatNotificationsDidChange, object: nil)
    }

    @objc private func taskDoneNotificationsChanged(_ sender: NSButton) {
        Settings.receiveTaskDoneNotifications = sender.state == .on
        updateWeChatControls()
    }

    @objc private func focusOnStartChanged(_ sender: NSButton) {
        Settings.petFocusOnStart = sender.state == .on
        NotificationCenter.default.post(name: .petBehaviorDidChange, object: nil)
    }

    @objc private func notifyOnWaitingChanged(_ sender: NSButton) {
        Settings.petNotifyOnWaiting = sender.state == .on
        NotificationCenter.default.post(name: .petBehaviorDidChange, object: nil)
    }

    @objc private func moodDecayChanged(_ sender: NSButton) {
        Settings.petMoodDecay = sender.state == .on
        NotificationCenter.default.post(name: .petBehaviorDidChange, object: nil)
    }

    @objc private func sedentaryChanged(_ sender: NSButton) {
        Settings.petSedentaryReminder = sender.state == .on
        updateBehaviorControls()
        NotificationCenter.default.post(name: .petBehaviorDidChange, object: nil)
    }

    @objc private func sedentaryStepperChanged(_ sender: NSStepper) {
        Settings.petSedentaryMinutes = sender.integerValue
        updateBehaviorControls()
        NotificationCenter.default.post(name: .petBehaviorDidChange, object: nil)
    }

    @objc private func nightDrowsyChanged(_ sender: NSButton) {
        Settings.petNightDrowsy = sender.state == .on
        NotificationCenter.default.post(name: .petBehaviorDidChange, object: nil)
    }

    @objc private func dockCornerChanged(_ sender: NSPopUpButton) {
        Settings.petDockCorner = sender.indexOfSelectedItem
        NotificationCenter.default.post(name: .dockCornerDidChange, object: nil)
    }

    @objc private func launchAtLoginChanged(_ sender: NSButton) {
        do {
            if sender.state == .on {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            PetView.log("开机自启切换失败: \(error)")
        }
        updateWindowControls()   // 以系统实际状态回填,失败时 UI 不至于与现实不符
    }

    @objc private func translateChanged(_ sender: NSButton) {
        Settings.petTranslate = sender.state == .on
        if sender.state == .on {
            _ = PetView.accessibilityTrusted(prompt: true)   // 首次开启即请求辅助功能权限(取选中文字所需)
        }
    }

    @objc private func doNotDisturbChanged(_ sender: NSButton) {
        Settings.petDoNotDisturb = sender.state == .on       // 下次提示出口读取即可,无需广播
    }

    @objc private func showSessionBadgeChanged(_ sender: NSButton) {
        Settings.petShowSessionBadge = sender.state == .on
        NotificationCenter.default.post(name: .petBehaviorDidChange, object: nil)  // 触发 PetView 立即显隐角标
    }

    @objc private func monitorChanged(_ sender: NSButton) {
        Settings.monitorEnabled = sender.state == .on
        TaskMonitor.reload()            // 即时起停内嵌服务
        updateMonitorControls()
        if sender.state == .on { TaskMonitor.openInBrowser() }   // 一开即在浏览器打开页面
    }

    @objc private func monitorPortChanged(_ sender: NSTextField) {
        if let p = Int(sender.stringValue.trimmingCharacters(in: .whitespaces)) { Settings.monitorPort = p }
        if Settings.monitorEnabled { TaskMonitor.reload() }      // 改端口需重起服务
        updateMonitorControls()
    }

    @objc private func openMonitor(_ sender: Any?) {
        if !Settings.monitorEnabled {   // 没挂载先挂载,免得打开空页
            Settings.monitorEnabled = true
            TaskMonitor.reload()
            updateMonitorControls()
        }
        TaskMonitor.openInBrowser()
    }

    @objc private func closeWindow(_ sender: Any?) {
        close()
    }

    // 窗口重新获得焦点时刷新权限状态:用户去系统设置点完授权再切回来,这里立刻反映最新结果。
    func windowDidBecomeKey(_ notification: Notification) {
        updatePermissionControls()
    }

    @objc private func openFullDiskAccess(_ sender: Any?) { openPrivacyPane("Privacy_AllFiles") }
    @objc private func openAccessibilitySettings(_ sender: Any?) { openPrivacyPane("Privacy_Accessibility") }

    /// 打开「系统设置 → 隐私与安全性」的指定子页:app 无权替自己授权,只能把主公带到位、由他手动开。
    private func openPrivacyPane(_ anchor: String) {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)") else { return }
        NSWorkspace.shared.open(url)
    }

    /// 刷新「权限」组状态文字:已授权显绿「已开启」、未授权显红「未开启」。
    /// 完全磁盘访问靠探测 TCC.db 可读性,辅助功能靠 AXIsProcessTrusted();自动化无可靠查询故不列状态。
    private func updatePermissionControls() {
        func mark(_ label: NSTextField, _ granted: Bool) {
            label.stringValue = granted ? "已开启" : "未开启"
            label.textColor = granted ? .systemGreen : .systemRed
        }
        mark(fdaStatusLabel, PetView.hasFullDiskAccess())
        mark(axStatusLabel, PetView.accessibilityTrusted(prompt: false))
    }

    private func updateValueLabel() {
        valueLabel.stringValue = String(format: "%.2f 秒", Settings.pounceDuration)
    }

    private func updateColorControls() {
        let autoAdaptColor = Settings.autoAdaptColor
        autoAdaptButton.state = autoAdaptColor ? .on : .off
        colorWell.isEnabled = !autoAdaptColor
        colorTitle.textColor = autoAdaptColor ? .secondaryLabelColor : .labelColor
    }

    private func updateWeChatControls() {
        weChatNotificationsButton.state = Settings.imNotificationsEnabled("receiveWeChatNotifications") ? .on : .off
        larkNotificationsButton.state = Settings.imNotificationsEnabled("receiveLarkNotifications") ? .on : .off
        taskDoneNotificationsButton.state = Settings.receiveTaskDoneNotifications ? .on : .off
        doNotDisturbButton.state = Settings.petDoNotDisturb ? .on : .off
    }

    private func updateCompanionControls() {
        focusOnStartButton.state = Settings.petFocusOnStart ? .on : .off
        notifyOnWaitingButton.state = Settings.petNotifyOnWaiting ? .on : .off
        showSessionBadgeButton.state = Settings.petShowSessionBadge ? .on : .off
    }

    private func updateBehaviorControls() {
        moodDecayButton.state = Settings.petMoodDecay ? .on : .off
        nightDrowsyButton.state = Settings.petNightDrowsy ? .on : .off
        let on = Settings.petSedentaryReminder
        sedentaryButton.state = on ? .on : .off
        sedentaryStepper.isEnabled = on
        sedentaryStepper.integerValue = Settings.petSedentaryMinutes
        sedentaryLabel.textColor = on ? .labelColor : .secondaryLabelColor
        sedentaryLabel.stringValue = "每 \(Settings.petSedentaryMinutes) 分钟"
    }

    private func updateWindowControls() {
        dockCornerPopup.selectItem(at: Settings.petDockCorner)
        launchAtLoginButton.state = (SMAppService.mainApp.status == .enabled) ? .on : .off
    }

    private func updateTranslateControls() {
        translateButton.state = Settings.petTranslate ? .on : .off
    }

    private func updateMonitorControls() {
        monitorButton.state = Settings.monitorEnabled ? .on : .off
        monitorPortField.stringValue = String(Settings.monitorPort)
        monitorNoteLabel.stringValue = Settings.monitorEnabled
            ? "运行中 · http://localhost:\(Settings.monitorPort)"
            : "关闭中 · 端口 \(Settings.monitorPort)"
        monitorNoteLabel.textColor = Settings.monitorEnabled ? .systemGreen : .secondaryLabelColor
    }
}

/// 把 cc/cx 命令简写幂等地确保进 ~/.zshrc——让"换台电脑装上桌宠"就自带 cc/cx,不必每台手动配别名。
/// 形式只能是 alias、不能装成 PATH 可执行:cc 是系统 C 编译器(/usr/bin/cc)的标准名,做成可执行文件丢进
/// PATH 靠前目录会遮蔽 /usr/bin/cc,令 make / ./configure / 原生模块编译全部错走到 claude 上;alias 只在
/// 交互式 shell 顶层展开,不污染脚本与编译,故安全。已有定义一律尊重、跳过,绝不改动主公现有别名。
@MainActor
enum ShellAliasInstaller {
    /// 要确保存在的命令简写,与 build.sh 写入 app 的 cc/cx 包装、主公 .zshrc 现有定义保持一致(放飞版:跳过确认)。
    static let entries: [(name: String, line: String)] = [
        ("cc", #"alias cc="claude --dangerously-skip-permissions""#),
        ("cx", #"alias cx="codex --dangerously-bypass-approvals-and-sandbox""#),
    ]

    struct Outcome {
        let path: String        // 目标 rc 文件
        let existed: [String]   // 已有定义、跳过的简写名
        let added: [String]     // 本次(将)追加的简写名;空 = 无需改动
        let appendText: String  // (将)追加到文件末尾的文本块(含来源注释);无追加则为空串
    }

    /// 幂等确保 ~/.zshrc 含 cc/cx alias。dryRun 只判定不落盘;path 可注入(供自测指向临时文件)。
    @discardableResult
    static func ensure(dryRun: Bool, path overridePath: String? = nil) -> Outcome {
        let path = overridePath
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".zshrc").path
        let existing = (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""
        let lines = existing.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)

        // 判定某简写是否已有"生效的"定义:整行去空白后以 alias <name>= 开头,注释行不算。
        func defined(_ name: String) -> Bool {
            let prefix = "alias \(name)="
            return lines.contains { raw in
                let t = raw.trimmingCharacters(in: .whitespaces)
                return !t.hasPrefix("#") && t.hasPrefix(prefix)
            }
        }

        var existed: [String] = []
        var addedNames: [String] = []
        var addedLines: [String] = []
        for entry in entries {
            if defined(entry.name) { existed.append(entry.name) }
            else { addedNames.append(entry.name); addedLines.append(entry.line) }
        }

        var appendText = ""
        if !addedLines.isEmpty {
            appendText = "\n# ClaudePet 桌宠自动添加:cc/cx 命令简写(放飞版,跳过确认)\n"
                + addedLines.joined(separator: "\n") + "\n"
            if !dryRun {
                var next = existing
                if !next.isEmpty && !next.hasSuffix("\n") { next += "\n" }  // 原文件不以换行结尾时先补,避免粘行
                next += appendText
                do {
                    try next.write(toFile: path, atomically: true, encoding: .utf8)
                    PetView.log("shell alias 写入 \(path):新增 \(addedNames.joined(separator: ","))")
                } catch {
                    PetView.log("shell alias 写入失败 \(path):\(error)")
                }
            }
        }
        return Outcome(path: path, existed: existed, added: addedNames, appendText: appendText)
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var window: NSWindow!
    private weak var petView: PetView?
    private var settingsWindowController: SettingsWindowController?
    private var remoteControlWindowController: RemoteControlWindowController?
    /// 任务完成提示节流:记下每个(工具+目录)上次弹的时间,窗口内重复来的直接跳过,免得连答几轮时连珠炮
    private var lastTaskDoneAt: [String: Date] = [:]
    private static let taskDoneThrottle: TimeInterval = 8

    func applicationDidFinishLaunching(_ notification: Notification) {
        PetView.log("ClaudePet 启动 feed-script-v2")
        let appSize = Style.canvasSize
        let screen = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        // 默认停在用户选定的角(缺省右下);origin 计算收敛进 DockCorner
        let origin = DockCorner.current.origin(in: screen, size: appSize)

        let win = NSWindow(
            contentRect: NSRect(origin: origin, size: appSize),
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        win.isOpaque = false
        win.backgroundColor = .clear
        // 刻意不用窗口级 hasShadow:它由系统按窗口位图生成,不跟随图层 transform 动画刷新,
        // 桌宠一跳/一摇旧阴影会残留成"第二个"重影。改用图层自带阴影(applyBaseShadow),随 transform 一起动。
        win.hasShadow = false
        win.level = .statusBar // 浮在普通窗口之上,微信提示横幅不容易被盖住
        // 跨所有桌面/空间显示,并能浮在全屏应用之上
        win.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        win.isMovableByWindowBackground = true // 整窗可拖拽
        let petView = PetView(frame: NSRect(origin: .zero, size: appSize))
        win.contentView = petView
        win.makeKeyAndOrderFront(nil)
        window = win
        self.petView = petView

        // 全局快捷键:取 Finder 选中项 → 扑过去吃 → 唤起分析(文件留在原位)。⌥⌘C 跑 claude,⌥⌘X 跑 codex(cx)。
        let mods = UInt32(cmdKey | optionKey)
        let okClaude = GlobalHotKey.register(keyCode: UInt32(kVK_ANSI_C), modifiers: mods) { [weak petView] in
            GlobalHotKey.feedFromFinder(into: petView, with: .claude)
        }
        let okCodex = GlobalHotKey.register(keyCode: UInt32(kVK_ANSI_X), modifiers: mods) { [weak petView] in
            GlobalHotKey.feedFromFinder(into: petView, with: .codex)
        }
        // ⌥⌘T:取任意应用选中文字,翻译后在桌宠头顶气泡显示(开关 Settings.petTranslate 在回调入口判定)
        let okTranslate = GlobalHotKey.register(keyCode: UInt32(kVK_ANSI_T), modifiers: mods) { [weak petView] in
            petView?.translateSelection()
        }
        // ⌥⌘V:把剪贴板里的文字喂给 claude(扑到鼠标处嚼一口再开会话),不模拟按键、无需辅助功能权限
        let okPaste = GlobalHotKey.register(keyCode: UInt32(kVK_ANSI_V), modifiers: mods) { [weak petView] in
            GlobalHotKey.feedClipboard(into: petView, with: .claude)
        }
        PetView.log("热键注册 ⌥⌘C(claude)=\(okClaude) ⌥⌘X(codex)=\(okCodex) ⌥⌘T(translate)=\(okTranslate) ⌥⌘V(paste)=\(okPaste)")

        // 设置里改停靠角 → 即时把窗口挪到新角
        NotificationCenter.default.addObserver(self, selector: #selector(handleDockCornerDidChange(_:)), name: .dockCornerDidChange, object: nil)

        // 远程遥控(Telegram):远程收到指令/答完一轮时,经回调让桌宠闪横幅(弱引用,避免循环持有)。
        // 回调统一在主线程触发(见 RemoteControl/TelegramBot),按设置起 cc/cx 轮询;设置变更后由配置窗 reload。
        RemoteControl.shared.onActivity = { [weak petView] tool, phase, summary in
            petView?.remoteActivity(tool: tool, phase: phase, summary: summary)
        }
        RemoteControl.shared.reload()

        // 任务监控:按"挂载监控系统"开关起停内嵌 HTTP 服务(默认关闭,不启动则零开销)。
        TaskMonitor.reload()

        // 首次在新机器上启动:幂等把 cc/cx 命令简写写进 ~/.zshrc(已有则跳过、绝不动主公现有定义),
        // 让"换台电脑装上桌宠"就自带 cc/cx;新开终端或 source ~/.zshrc 后生效。
        let aliasOutcome = ShellAliasInstaller.ensure(dryRun: false)
        if !aliasOutcome.added.isEmpty {
            petView.flashInfo("已为你装好 \(aliasOutcome.added.joined(separator: "/")) 命令,新开终端即可用")
        }
    }

    @objc private func handleDockCornerDidChange(_ notification: Notification) {
        guard let window = window else { return }
        let visible = window.screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? window.frame
        window.setFrameOrigin(DockCorner.current.origin(in: visible, size: window.frame.size))
    }

    @objc func showSettings(_ sender: Any?) {
        if settingsWindowController == nil {
            settingsWindowController = SettingsWindowController()
        }
        guard let settingsWindowController else { return }
        settingsWindowController.showWindow(nil)
        settingsWindowController.window?.center()
        settingsWindowController.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// 右键「远程遥控(Telegram)…」:开独立配置窗,填两个 bot token 与 chat id 白名单;保存即 RemoteControl.reload。
    @objc func showRemoteControl(_ sender: Any?) {
        if remoteControlWindowController == nil {
            remoteControlWindowController = RemoteControlWindowController()
        }
        guard let remoteControlWindowController else { return }
        remoteControlWindowController.showWindow(nil)
        remoteControlWindowController.window?.center()
        remoteControlWindowController.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    // MARK: 任务完成通知:外部 CLI 完成后 open "claudepet://done?tool=...&cwd=..." 唤起报喜横幅
    // Claude Code 的 Stop 钩子 / Codex 的 notify 各自落到一条 open 命令;Info.plist 已声明 claudepet 协议,
    // 系统据此把 GetURL 事件转给下方回调。只读 URL 参数、弹横幅,不碰任何文件。
    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls where url.scheme == "claudepet" {
            handleClaudePetURL(url)
        }
    }

    private func handleClaudePetURL(_ url: URL) {
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        let phase = url.host ?? components?.host ?? ""
        guard ["start", "waiting", "done"].contains(phase) else { return }   // host 即生命周期相位
        let items = components?.queryItems ?? []
        let tool = items.first { $0.name == "tool" }?.value ?? ""
        let cwd = items.first { $0.name == "cwd" || $0.name == "dir" }?.value
        let task = items.first { $0.name == "task" }?.value
        let tty = items.first { $0.name == "tty" }?.value
        let ts = (items.first { $0.name == "ts" }?.value).flatMap { Double($0) }   // 事件生成时间戳,供乱序定序;老 hook 无此参 → nil
        let pid = (items.first { $0.name == "pid" }?.value).flatMap { pid_t($0) }   // 会话进程 pid,供超时兜底前 kill(0) 探活;老 hook 无此参 → nil
        let rawSid = items.first { $0.name == "sid" }?.value
        let sid = (rawSid?.isEmpty == false) ? rawSid! : "\(tool)|\(cwd ?? "")"   // 脚本已兜底,这里再防空
        // 横幅节流只抑制"横幅弹出"(waiting/done 同 相位|工具|目录 在 throttle 秒内不重复弹,免连珠炮);
        // 会话状态与角标更新【不受节流影响】,始终实时——否则连答多轮时角标会卡住不动。
        var suppressBanner = false
        if phase != "start" {
            let throttleKey = "\(phase)|\(tool)|\(cwd ?? "")"
            let now = Date()
            if let last = lastTaskDoneAt[throttleKey], now.timeIntervalSince(last) < AppDelegate.taskDoneThrottle {
                suppressBanner = true
                PetView.log("陪跑横幅节流(\(Int(AppDelegate.taskDoneThrottle))s 内重复),仅抑制横幅、角标照常更新 \(url.absoluteString)")
            } else {
                lastTaskDoneAt[throttleKey] = now
            }
        }
        let message = AppDelegate.companionMessage(phase: phase, tool: tool, cwd: cwd, task: task)
        PetView.log("陪跑事件 \(url.absoluteString) → [\(phase)] \(message)")
        petView?.handleCompanionEvent(phase: phase, sid: sid, message: message, cwd: cwd, tty: tty, ts: ts, pid: pid, suppressBanner: suppressBanner)
    }

    /// 据工具名与工作目录拼报喜文案。抽成静态纯函数,便于 --notify-dryrun 离线核对。
    static func taskDoneMessage(tool: String, cwd: String?, task: String?) -> String {
        let who: String
        switch tool.lowercased() {
        case "codex", "cx": who = "Codex"
        case "claude", "cc": who = "Claude"
        default: who = tool   // 未知工具原样带出;空字符串走下方兜底
        }
        let label = who.isEmpty ? "完成" : who
        // 有任务简介:直接"客户端 · 任务",一眼看清谁干完了哪桩(横幅高度会自适应换行)
        if let task = task?.trimmingCharacters(in: .whitespacesAndNewlines), !task.isEmpty {
            return "\(label) · \(task)"
        }
        // 退而求其次用目录名;再不行报个"该主公了"。文案表"答完一轮"而非整任务完成
        if let cwd, !cwd.isEmpty {
            let name = (cwd as NSString).lastPathComponent
            if !name.isEmpty, name != "/" {
                return who.isEmpty ? "答完了 · \(name)" : "\(who) 答完了 · \(name)"
            }
        }
        return who.isEmpty ? "答完了,该主公了" : "\(who) 答完了,该主公了"
    }

    /// 据相位拼陪跑横幅文案。done 复用 taskDoneMessage(含任务简介);start/waiting 用目录名。抽静态纯函数便于 --notify-dryrun 离线核对。
    static func companionMessage(phase: String, tool: String, cwd: String?, task: String?) -> String {
        let who: String
        switch tool.lowercased() {
        case "codex", "cx": who = "Codex"
        case "claude", "cc": who = "Claude"
        default: who = tool
        }
        let dir: String? = cwd.flatMap {
            let n = ($0 as NSString).lastPathComponent
            return (!n.isEmpty && n != "/") ? n : nil
        }
        switch phase {
        case "start":
            let w = who.isEmpty ? "开工了" : "\(who) 开工了"
            return dir.map { "\(w) · \($0)" } ?? w
        case "waiting":
            let w = who.isEmpty ? "要你拍板" : "\(who) 要你拍板"
            return dir.map { "\(w) · \($0)" } ?? w
        default:
            return taskDoneMessage(tool: tool, cwd: cwd, task: task)
        }
    }
}

// MARK: - 离屏渲染自测
// 不依赖屏幕、不触碰桌面隐私,把一帧图标渲染成 PNG,供本地核对外观。
@MainActor
private func renderSnapshot(to path: String, mouthOpen: CGFloat = 0, eyeLook: CGVector = CGVector(dx: 0, dy: 0), eyeMode: PetView.EyeMode = .normal, runPhase: Int = 0, badgeRunning: Int = 0, badgeWaiting: Int = 0) {
    let dim: CGFloat = 256
    let view = PetView(frame: NSRect(x: 0, y: 0, width: dim, height: dim))
    view.prepareSnapshot(withBackground: true, mouthOpen: mouthOpen, eyeLook: eyeLook, eyeMode: eyeMode, runPhase: runPhase)

    let image = NSImage(size: NSSize(width: dim, height: dim))
    image.lockFocus()
    view.draw(view.bounds)
    if badgeRunning + badgeWaiting > 0 {                // 叠画会话角标核对样式(位置取星芒右上示意)
        let badge = PetView.sessionBadgeImage(running: badgeRunning, waiting: badgeWaiting)
        let bs = badge.size
        badge.draw(in: CGRect(x: dim * 0.55, y: dim * 0.58, width: bs.width, height: bs.height))
    }
    image.unlockFocus()

    guard let tiff = image.tiffRepresentation,
          let rep = NSBitmapImageRep(data: tiff),
          let png = rep.representation(using: .png, properties: [:]) else {
        FileHandle.standardError.write(Data("渲染失败\n".utf8))
        exit(1)
    }
    do {
        try png.write(to: URL(fileURLWithPath: path))
        print("已输出快照:\(path)")
    } catch {
        FileHandle.standardError.write(Data("写入失败:\(error)\n".utf8))
        exit(1)
    }
}

// MARK: - 入口
// 程序启动即处于主线程,assumeIsolated 让顶层安全进入主 actor 上下文。

/// cc/cx 写入逻辑的离线自测:在临时文件上真跑写入,核对幂等与各类已有定义场景;不碰真实 ~/.zshrc。
@MainActor
func runInstallAliasesSelfTest() -> Bool {
    let fm = FileManager.default
    let dir = NSTemporaryDirectory()
    var pass = true
    func check(_ cond: Bool, _ desc: String) {
        print((cond ? "PASS " : "FAIL ") + desc); if !cond { pass = false }
    }
    func freshFile(_ name: String, _ content: String?) -> String {
        let p = (dir as NSString).appendingPathComponent(name)
        try? fm.removeItem(atPath: p)
        if let content { try? content.write(toFile: p, atomically: true, encoding: .utf8) }
        return p
    }
    func read(_ p: String) -> String { (try? String(contentsOfFile: p, encoding: .utf8)) ?? "" }

    // 场景1:文件不存在 → 追加 cc、cx 两行
    let p1 = freshFile("claudepet-alias-st1.zshrc", nil)
    let r1 = ShellAliasInstaller.ensure(dryRun: false, path: p1)
    check(r1.added == ["cc", "cx"] && r1.existed.isEmpty, "文件不存在 → 追加 cc、cx")
    let body1 = read(p1)
    check(body1.contains(#"alias cc="claude --dangerously-skip-permissions""#)
        && body1.contains(#"alias cx="codex --dangerously-bypass-approvals-and-sandbox""#),
        "文件不存在 → 落盘两行 alias")

    // 场景2:对场景1产物复跑 → 幂等,不新增、内容不变
    let before2 = read(p1)
    let r2 = ShellAliasInstaller.ensure(dryRun: false, path: p1)
    check(r2.added.isEmpty && r2.existed == ["cc", "cx"], "复跑 → 幂等不重复")
    check(read(p1) == before2, "复跑 → 文件内容一字不变")

    // 场景3:只有 cc → 只补 cx
    let p3 = freshFile("claudepet-alias-st3.zshrc", "alias cc=\"claude --dangerously-skip-permissions\"\n")
    let r3 = ShellAliasInstaller.ensure(dryRun: false, path: p3)
    check(r3.existed == ["cc"] && r3.added == ["cx"], "已有 cc → 只补 cx")

    // 场景4:cc 被注释掉 → 视为未定义,补 cc 与 cx
    let p4 = freshFile("claudepet-alias-st4.zshrc", "# alias cc=\"old\"\n")
    let r4 = ShellAliasInstaller.ensure(dryRun: false, path: p4)
    check(r4.added.contains("cc") && r4.added.contains("cx"), "注释掉的 cc 不算 → 补 cc、cx")

    // 场景5:主公自定义了 cc(不同定义) → 尊重不覆盖,只补 cx
    let p5 = freshFile("claudepet-alias-st5.zshrc", "alias cc=\"claude\"\n")
    let r5 = ShellAliasInstaller.ensure(dryRun: false, path: p5)
    check(r5.existed.contains("cc") && !r5.added.contains("cc"), "自定义 cc → 尊重不覆盖")
    check(read(p5).contains("alias cc=\"claude\"") && r5.added == ["cx"], "自定义 cc → 原定义保留、只补 cx")

    for n in ["claudepet-alias-st1.zshrc", "claudepet-alias-st3.zshrc", "claudepet-alias-st4.zshrc", "claudepet-alias-st5.zshrc"] {
        try? fm.removeItem(atPath: (dir as NSString).appendingPathComponent(n))
    }
    return pass
}

MainActor.assumeIsolated {
    let arguments = CommandLine.arguments
    if let idx = arguments.firstIndex(of: "--render-test") {
        // 自测模式:渲染一帧后退出
        let out = idx + 1 < arguments.count ? arguments[idx + 1] : "/tmp/claudepet.png"
        renderSnapshot(to: out)
        exit(0)
    }

    if let idx = arguments.firstIndex(of: "--render-eat") {
        // 自测模式:渲染“张嘴进食”的一帧后退出,核对嘴的位置与大小
        let out = idx + 1 < arguments.count ? arguments[idx + 1] : "/tmp/claudepet-eat.png"
        renderSnapshot(to: out, mouthOpen: 1)
        exit(0)
    }

    if let idx = arguments.firstIndex(of: "--render-look") {
        // 自测模式:指定原图两个空位的偏移方向后渲染一帧,用法:--render-look [out.png] [dx] [dy]
        let out = idx + 1 < arguments.count ? arguments[idx + 1] : "/tmp/claudepet-look.png"
        let dx = idx + 2 < arguments.count ? Double(arguments[idx + 2]) ?? 0 : 1
        let dy = idx + 3 < arguments.count ? Double(arguments[idx + 3]) ?? 0 : 0
        renderSnapshot(to: out, eyeLook: CGVector(dx: dx, dy: dy))
        exit(0)
    }

    if let idx = arguments.firstIndex(of: "--render-blink") {
        // 自测模式:渲染"闭眼"一帧(眨眼/哈欠时的眼形),核对水平细缝位置
        let out = idx + 1 < arguments.count ? arguments[idx + 1] : "/tmp/claudepet-blink.png"
        renderSnapshot(to: out, eyeMode: .closed)
        exit(0)
    }

    if let idx = arguments.firstIndex(of: "--render-happy") {
        // 自测模式:渲染"眯眼笑"一帧(弯月眼),核对悬停互动的笑脸
        let out = idx + 1 < arguments.count ? arguments[idx + 1] : "/tmp/claudepet-happy.png"
        renderSnapshot(to: out, eyeMode: .happy)
        exit(0)
    }

    if let idx = arguments.firstIndex(of: "--render-run") {
        // 自测模式:渲染跑步腿一帧,用法:--render-run [out.png] [1|2]
        let out = idx + 1 < arguments.count ? arguments[idx + 1] : "/tmp/claudepet-run.png"
        let phase = idx + 2 < arguments.count ? Int(arguments[idx + 2]) ?? 1 : 1
        renderSnapshot(to: out, runPhase: phase)
        exit(0)
    }

    if let idx = arguments.firstIndex(of: "--render-badge") {
        // 自测模式:渲染星芒 + 会话角标一帧;用法:--render-badge [out.png] [running] [waiting]
        let out = idx + 1 < arguments.count ? arguments[idx + 1] : "/tmp/claudepet-badge.png"
        let r = idx + 2 < arguments.count ? Int(arguments[idx + 2]) ?? 1 : 1
        let w = idx + 3 < arguments.count ? Int(arguments[idx + 3]) ?? 0 : 0
        renderSnapshot(to: out, badgeRunning: r, badgeWaiting: w)
        exit(0)
    }

    if let idx = arguments.firstIndex(of: "--feed-dryrun") {
        // 自测模式:打印投喂脚本(不执行),核对路径转义与命令拼装
        // 用法:--feed-dryrun <路径> [claude|codex],默认 claude
        let path = idx + 1 < arguments.count ? arguments[idx + 1] : "/tmp"
        let tool: FeedTool = (idx + 2 < arguments.count && arguments[idx + 2] == "codex") ? .codex : .claude
        print(PetView.feedScript(for: URL(fileURLWithPath: path), tool: tool))
        exit(0)
    }

    if let idx = arguments.firstIndex(of: "--ask-dryrun") {
        // 自测模式:打印"喂一段文字"的投喂脚本(不执行),核对家目录 cd 与 prompt 转义
        // 用法:--ask-dryrun <文本> [claude|codex],默认 claude
        let text = idx + 1 < arguments.count ? arguments[idx + 1] : "这段报错是什么意思"
        let tool: FeedTool = (idx + 2 < arguments.count && arguments[idx + 2] == "codex") ? .codex : .claude
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        print(PetView.feedScript(workingDir: home, prompt: text, tool: tool))
        exit(0)
    }

    if let idx = arguments.firstIndex(of: "--translate-dryrun") {
        // 自测模式:给定文本,打印翻译指令并真翻一次,核对 cc/claude 定位、prompt 拼装与译文干净度
        // 用法:--translate-dryrun <文本>,默认一句英文
        let text = idx + 1 < arguments.count ? arguments[idx + 1] : "Hello world, how are you today?"
        print("翻译指令:\n\(PetView.translatePrompt(for: text))")
        print("----")
        if let translated = PetView.translate(text) {
            print("译文:\(translated)")
        } else {
            print("翻译失败:未定位到 claude CLI 或调用出错")
        }
        exit(0)
    }

    if arguments.contains("--finder-selection") {
        // 自测模式:打印当前 Finder 选中项路径后退出(会触发自动化授权),核对"取文件"这步
        let paths = PetView.finderSelectionPaths()
        print(paths.isEmpty ? "(无 Finder 选中项)" : paths.joined(separator: "\n"))
        exit(0)
    }

    if arguments.contains("--wechat-detect-dryrun") {
        // 自测模式:不触发桌宠提示,只打印当前微信未读探测状态,用于排查辅助功能权限和微信版本差异
        print(PetView.weChatDetectionStatus())
        exit(0)
    }

    if arguments.contains("--wechat-dump") {
        // 临时诊断:把 Dock 与微信辅助功能树的真实字段 dump 到 /tmp/claudepet.log(命令行下若未授权则为空)
        PetView.dumpWeChatAccessibilityTree()
        print("已尝试导出微信探测详情到 /tmp/claudepet.log")
        exit(0)
    }

    if let idx = arguments.firstIndex(of: "--notify-dryrun") {
        // 自测模式:给定 claudepet:// URL,打印解析出的工具/目录与最终横幅文案,核对 URL 解析与文案拼装
        // 用法:--notify-dryrun [claudepet://done?tool=codex&cwd=/path/to/repo],默认 claude
        let raw = idx + 1 < arguments.count ? arguments[idx + 1] : "claudepet://done?tool=claude"
        guard let url = URL(string: raw) else {
            FileHandle.standardError.write(Data("无法解析 URL:\(raw)\n".utf8))
            exit(1)
        }
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        let items = components?.queryItems ?? []
        let tool = items.first { $0.name == "tool" }?.value ?? ""
        let cwd = items.first { $0.name == "cwd" || $0.name == "dir" }?.value
        let task = items.first { $0.name == "task" }?.value
        let tty = items.first { $0.name == "tty" }?.value
        let ts = (items.first { $0.name == "ts" }?.value).flatMap { Double($0) }
        let pid = (items.first { $0.name == "pid" }?.value).flatMap { pid_t($0) }
        let phase = url.host ?? components?.host ?? ""
        let sid = items.first { $0.name == "sid" }?.value
        print("scheme=\(url.scheme ?? "(无)") phase=\(phase.isEmpty ? "(无)" : phase)")
        print("tool=\(tool.isEmpty ? "(空)" : tool) sid=\(sid ?? "(无)") cwd=\(cwd ?? "(无)") task=\(task ?? "(无)")")
        print("tty=\(tty ?? "(无)") ts=\(ts.map { String($0) } ?? "(无)") pid=\(pid.map { String($0) } ?? "(无)")")
        let normalizedPhase = ["start", "waiting", "done"].contains(phase) ? phase : "done"
        print("横幅文案:\(AppDelegate.companionMessage(phase: normalizedPhase, tool: tool, cwd: cwd, task: task))")
        if let pid {
            print("存活探测:会话进程 pid=\(pid) → 超时兜底前先 kill(0) 探活,进程退出即清角标(不等10分钟);进程在则保留(不受10分钟限,30分钟硬上限)")
        } else {
            print("存活探测:无 pid(老 hook / python 降级) → 退回纯 10 分钟超时兜底")
        }
        // 点横幅"回现场"的去向:带合法 tty 则按 tty 精确回那一个终端窗口,否则退回整 App 唤前台 / Finder 打开目录
        if let tty, tty.hasPrefix("/dev/tty") {
            print("回现场:按 tty=\(tty) 精确 focus 终端窗口(Ghostty/iTerm2/Terminal.app 命中其一)")
        } else {
            print("回现场:无有效 tty → 退回整 App 唤前台 / Finder 打开 \(cwd ?? "(无)")")
        }
        exit(0)
    }

    if let idx = arguments.firstIndex(of: "--focus-tty") {
        // 自测模式:真实跑"按 tty 回到终端窗口"这条链,实测 Ghostty/iTerm2/Terminal.app 的定位脚本是否命中。
        // 用法:--focus-tty /dev/ttys003。会把承载该 tty 的终端窗口唤到前台(真切窗口,非离屏)。
        guard idx + 1 < arguments.count else {
            FileHandle.standardError.write(Data("用法:--focus-tty /dev/ttysXXX\n".utf8))
            exit(1)
        }
        let tty = arguments[idx + 1]
        let ok = PetView.focusTerminalSurface(tty: tty)
        print("focusTerminalSurface(tty=\(tty)) → \(ok ? "命中,已唤前台" : "未命中(tty 非法 / 窗口已关 / 无对应终端在跑)")")
        exit(ok ? 0 : 2)
    }

    if let idx = arguments.firstIndex(of: "--telegram-dryrun") {
        // 自测模式:离线打印远程遥控将执行的 cc/cx 命令(首轮无会话 + 续接带会话 id 两种),不连网、不起 agent 进程。
        // 复用 AgentRunner 的真函数,核对参数拼装与转义和真跑一致。用法:--telegram-dryrun <claude|codex> <文本>,默认 claude。
        let tool: FeedTool = (idx + 1 < arguments.count && arguments[idx + 1] == "codex") ? .codex : .claude
        let text = idx + 2 < arguments.count ? arguments[idx + 2] : "帮我看看这个报错"
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let exe = AgentRunner.resolveExecutable(for: tool)   // 本地 command -v 定位,不连网
        let lastFile = NSTemporaryDirectory() + "claudepet-remote-\(tool == .codex ? "cx" : "cc")-last.txt"
        // shell 风格展示:含空格/引号/空串的参数用单引号包起,便于肉眼核对转义
        func show(_ args: [String]) -> String {
            ([exe ?? tool.label] + args).map { arg in
                (arg.contains(" ") || arg.contains("\"") || arg.contains("'") || arg.isEmpty)
                    ? "'" + arg.replacingOccurrences(of: "'", with: "'\\''") + "'"
                    : arg
            }.joined(separator: " ")
        }
        print("远程遥控 dryrun(\(tool.label)):不连网,仅打印将执行的命令")
        print("可执行:\(exe ?? "未定位到 \(tool.label) CLI(真跑时会在聊天回报错误)")")
        print("工作目录:\(home)")
        let first = AgentRunner.command(for: tool, prompt: text, sessionID: nil, cwd: home, lastFile: lastFile)
        print("首轮(无会话):\n  \(show(first))")
        let resume = AgentRunner.command(for: tool, prompt: text, sessionID: "SAMPLE-SESSION-ID", cwd: home, lastFile: lastFile)
        print("续接(带会话 id):\n  \(show(resume))")
        exit(0)
    }

    if let idx = arguments.firstIndex(of: "--telegram-stream-dryrun") {
        // 自测模式:离线核对流式进度解析。喂内置样本 JSONL(claude / codex 各一组真实事件骨架)给 AgentRunner.parseStreamLine,
        // 打印提取出的进度行、最终正文与会话 id;不连网、不起进程。用法:--telegram-stream-dryrun <claude|codex>,默认 claude。
        let tool: FeedTool = (idx + 1 < arguments.count && arguments[idx + 1] == "codex") ? .codex : .claude
        let samples: [String]
        switch tool {
        case .claude:
            samples = [
                #"{"type":"system","subtype":"init","session_id":"SID-CC","model":"claude"}"#,
                #"{"type":"assistant","message":{"content":[{"type":"text","text":"先看一眼文件"},{"type":"tool_use","name":"Read","input":{"file_path":"/a/b/main.swift"}}]},"session_id":"SID-CC"}"#,
                #"{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Bash","input":{"command":"swift build -c release && echo done"}}]},"session_id":"SID-CC"}"#,
                #"{"type":"result","subtype":"success","result":"已修好,共改两处。","session_id":"SID-CC"}"#,
            ]
        case .codex:
            samples = [
                #"{"type":"thread.started","thread_id":"TID-CX"}"#,
                #"{"type":"turn.started"}"#,
                #"{"type":"item.started","item":{"id":"i0","type":"command_execution","command":"/bin/zsh -lc 'ls -la'","status":"in_progress"}}"#,
                #"{"type":"item.completed","item":{"id":"i0","type":"command_execution","command":"/bin/zsh -lc 'ls -la'","exit_code":0,"status":"completed"}}"#,
                #"{"type":"item.completed","item":{"id":"i1","type":"agent_message","text":"主公,目录里有 3 个文件。"}}"#,
                #"{"type":"turn.completed","usage":{}}"#,
            ]
        }
        print("流式进度 dryrun(\(tool.label)):逐行喂 parseStreamLine,核对进度提取(不连网)")
        var finalText = ""
        var sid = "(未捕获)"
        for line in samples {
            for ev in AgentRunner.parseStreamLine(line, tool: tool) {
                switch ev {
                case .progress(let p): print("  进度│ \(p)")
                case .finalText(let t): finalText = t
                case .session(let s): sid = s
                case .metrics(let m): print("  计量│ 时长 \(m.cliDurationMs ?? -1)ms 花费 $\(m.costUSD ?? 0)")
                }
            }
        }
        print("最终正文│ \(finalText.isEmpty ? "(空)" : finalText)")
        print("会话 id │ \(sid)")
        exit(0)
    }

    if let idx = arguments.firstIndex(of: "--telegram-live-test") {
        // 自测模式:真跑一轮 AgentRunner.run(会真实调用 claude/codex CLI、消耗额度),把流式进度逐条打印,
        // 末尾给最终正文与会话 id。核对"边读边回调"在真进程上确实流式、并发不死锁。用法:--telegram-live-test <claude|codex> <文本>
        let tool: FeedTool = (idx + 1 < arguments.count && arguments[idx + 1] == "codex") ? .codex : .claude
        let text = idx + 2 < arguments.count ? arguments[idx + 2] : "只回复两个字:好的"
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        print("live-test(\(tool.label)):真跑一轮(会消耗额度),实时进度如下 ——")
        let reply = AgentRunner.run(tool: tool, prompt: text, sessionID: nil, cwd: home, ioTag: "livetest") { line in
            print("  进度│ \(line)")
        }
        print("最终正文│ \(reply.text)")
        print("会话 id │ \(reply.sessionID ?? "(nil)")")
        exit(0)
    }

    if arguments.contains("--feishu-pb-test") {
        // 自测模式:飞书长连接帧的 protobuf 编解码往返。构造典型数据帧 encode→decode,核对字段无损;并打印/还原 ping 帧。不连网。
        print("飞书 protobuf 往返自测(离线)")
        var f = FeishuFrame()
        f.seqID = 12345; f.logID = 67890; f.service = 7; f.method = FeishuFrame.methodData
        f.headers = [("type", "event"), ("message_id", "m-1"), ("sum", "1"), ("seq", "0")]
        f.payloadEncoding = "json"; f.payloadType = "event"
        f.payload = Data(#"{"schema":"2.0"}"#.utf8)
        let bytes = f.encoded()
        guard let d = FeishuFrame.decode(bytes) else { print("  ✘ 数据帧解码失败"); exit(2) }
        let ok = d.seqID == f.seqID && d.logID == f.logID && d.service == f.service && d.method == f.method
            && d.headers.count == f.headers.count && d.header("message_id") == "m-1"
            && d.payloadEncoding == "json" && d.payloadType == "event" && d.payload == f.payload
        print("  数据帧字段还原:\(ok ? "✔ 一致" : "✘ 不一致")")
        print("  headers:\(d.headers.map { "\($0.key)=\($0.value)" }.joined(separator: ", "))")
        print("  payload:\(String(decoding: d.payload, as: UTF8.self))")
        let ping = FeishuFrame.ping(service: 7).encoded()
        print("  ping 帧(\(ping.count) 字节):\(ping.map { String(format: "%02x", $0) }.joined())")
        let pingOK = FeishuFrame.decode(ping).map { $0.method == FeishuFrame.methodControl && $0.service == 7 && $0.header("type") == "ping" } ?? false
        print("  ping 帧还原:\(pingOK ? "✔ method=Control service=7 type=ping" : "✘ 还原异常")")
        exit(ok && pingOK ? 0 : 2)
    }

    if arguments.contains("--feishu-event-dryrun") {
        // 自测模式:喂样本 im.message.receive_v1 事件 JSON 给 FeishuBot.parse,核对解析(私聊 / 群里 @ / 非文字三种)。不连网。
        let samples: [(String, String)] = [
            ("私聊 text", #"{"schema":"2.0","header":{"event_id":"evt-p2p-1","event_type":"im.message.receive_v1"},"event":{"sender":{"sender_id":{"open_id":"ou_zhang"}},"message":{"message_id":"om_1","chat_id":"oc_priv","chat_type":"p2p","message_type":"text","content":"{\"text\":\"帮我看看报错\"}"}}}"#),
            ("群里 @机器人", #"{"schema":"2.0","header":{"event_id":"evt-grp-1","event_type":"im.message.receive_v1"},"event":{"sender":{"sender_id":{"open_id":"ou_zhang"}},"message":{"message_id":"om_2","chat_id":"oc_group","chat_type":"group","message_type":"text","content":"{\"text\":\"@_user_1 跑一下测试\"}","mentions":[{"key":"@_user_1","id":{"open_id":"ou_bot"},"name":"cc"}]}}}"#),
            ("非文字", #"{"schema":"2.0","header":{"event_id":"evt-img","event_type":"im.message.receive_v1"},"event":{"sender":{"sender_id":{"open_id":"ou_zhang"}},"message":{"message_id":"om_3","chat_id":"oc_priv","chat_type":"p2p","message_type":"image","content":"{\"image_key\":\"img_x\"}"}}}"#),
        ]
        print("飞书事件解析 dryrun(离线):")
        for (name, json) in samples {
            guard let inc = FeishuBot.parse(payload: Data(json.utf8)) else { print("  [\(name)] 解析失败"); continue }
            print("  [\(name)] event_id=\(inc.eventID) open_id=\(inc.senderOpenID) chat=\(inc.chatType)/\(inc.chatID)")
            print("           type=\(inc.messageType) mentioned=\(inc.mentioned) text=「\(inc.text)」")
        }
        exit(0)
    }

    if arguments.contains("--permissions-dryrun") {
        // 自测模式:打印「权限」组探测到的状态,核对检测逻辑跑得通。
        // 注意:命令行跑的是裸可执行,TCC 身份与 /Applications 里的 .app 不同,状态仅反映本次调用进程,不代表桌宠本体。
        print("完全磁盘访问:\(PetView.hasFullDiskAccess() ? "已开启" : "未开启")")
        print("辅助功能:\(PetView.accessibilityTrusted(prompt: false) ? "已开启" : "未开启")")
        exit(0)
    }

    if arguments.contains("--install-aliases-dryrun") {
        // 自测:只读真实 ~/.zshrc,打印 cc/cx 判定与将追加的内容,不落盘。本机已配则应显示"无需改动"。
        let r = ShellAliasInstaller.ensure(dryRun: true)
        print("目标文件:\(r.path)")
        print("已存在(跳过):\(r.existed.isEmpty ? "无" : r.existed.joined(separator: ", "))")
        print("将追加:\(r.added.isEmpty ? "无(无需改动)" : r.added.joined(separator: ", "))")
        if !r.appendText.isEmpty { print("追加内容:\(r.appendText)", terminator: "") }
        exit(0)
    }

    if arguments.contains("--install-aliases-selftest") {
        // 自测:临时文件上真跑写入,核对幂等与各类已有定义场景;不碰真实 ~/.zshrc。全过打印 PASS、退 0。
        exit(runInstallAliasesSelfTest() ? 0 : 1)
    }

    let app = NSApplication.shared
    app.setActivationPolicy(.accessory) // 不占 Dock、不抢焦点,等价 LSUIElement
    let delegate = AppDelegate()
    app.delegate = delegate
    app.run()
}
