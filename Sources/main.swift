import AppKit
import ApplicationServices
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
private enum Settings {
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

    /// 泛化的 IM 通知开关读写(微信/飞书共用),按 UserDefaults 键存取,缺省关闭。
    static func imNotificationsEnabled(_ key: String) -> Bool {
        UserDefaults.standard.object(forKey: key) == nil ? false : UserDefaults.standard.bool(forKey: key)
    }

    static func setIMNotificationsEnabled(_ key: String, _ on: Bool) {
        UserDefaults.standard.set(on, forKey: key)
    }
}

private extension Notification.Name {
    static let petColorDidChange = Notification.Name("ClaudePet.petColorDidChange")
    static let autoAdaptColorDidChange = Notification.Name("ClaudePet.autoAdaptColorDidChange")
    static let weChatNotificationsDidChange = Notification.Name("ClaudePet.weChatNotificationsDidChange")
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
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("不支持 Interface Builder 加载") }

    deinit {
        NotificationCenter.default.removeObserver(self)
        ambientColorTimer?.invalidate()
        weChatNotificationTimer?.invalidate()
        noticeHintTimer?.invalidate()
        bannerHideTimer?.invalidate()
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

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard let window else { return }
        iconLayer.contentsScale = window.backingScaleFactor // 适配真实屏幕缩放,保证清晰
        bannerTextLayer.contentsScale = window.backingScaleFactor
        render()              // 缩放确定后重绘一帧,保证清晰
        startBreathing()
        startEyeFollow()
        updateBackgroundColorSampling()
        updateWeChatNotificationMonitor()
        scheduleIdle()        // 启动空闲动作调度
    }

    // MARK: 呼吸动画(交给 Core Animation,无需逐帧重绘)
    // 常态在 0.95~1.0 间缓缓缩放;悬停时换成放大区间(见 onHoverBegin),呼吸不停、只是"鼓"起来。
    private func startBreathing(scaleLow: CGFloat = 0.95, scaleHigh: CGFloat = 1.0) {
        let breathe = CABasicAnimation(keyPath: "transform.scale")
        breathe.fromValue = scaleLow
        breathe.toValue = scaleHigh
        breathe.duration = Style.breathPeriod / 2
        breathe.autoreverses = true
        breathe.repeatCount = .infinity
        breathe.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        iconLayer.add(breathe, forKey: "breathe") // 同 key 重加即替换,实现常态↔放大切换
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
    private func showWeChatNotificationHint(message: String, duration: TimeInterval = 6.0) {
        flashNotice(message, accent: Self.weChatAccent, duration: duration)
    }

    /// Claude Code / Codex 任务完成报喜:橙色(主色)横幅 + 同一套庆祝动作。
    func showTaskDoneHint(message: String, duration: TimeInterval = 6.0) {
        flashNotice(message, accent: Style.orange, duration: duration)
    }

    /// 通用通知观感:顶部弹横幅(accent 决定边框色)+ 发光 + 跳 + 摇 + 眯眼笑,定时复位。
    /// 微信未读与任务完成共用,只是文案与强调色不同——避免两套重复的提示逻辑。
    private func flashNotice(_ message: String, accent: NSColor, duration: TimeInterval = 6.0) {
        showBanner(message, accent: accent, duration: duration)
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

    private func showBanner(_ message: String, accent: NSColor, duration: TimeInterval) {
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
        isHovering = true
        eyeMode = .happy                 // 眯眼笑
        render()
        setFeedGlow(true)                // 点亮橙光
        startBreathing(scaleLow: 1.08, scaleHigh: 1.18) // 鼓起来:放大版呼吸
        jump()                           // 开心蹦一下
    }

    override func mouseExited(with event: NSEvent) {
        guard isHovering else { return }
        isHovering = false
        eyeMode = .normal
        render()
        if chewTimer == nil { setFeedGlow(false) } // 进食中则交给进食收尾,避免抢着熄灯
        startBreathing()                 // 复位常态呼吸
    }

    // MARK: 点击互动
    // 用 mouseUp 触发"吃一口",不 override mouseDown,保留 isMovableByWindowBackground 整窗拖拽。
    override func mouseUp(with event: NSEvent) {
        eatBite()
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
        guard !isHovering, !isPouncing, chewTimer == nil, biteTimer == nil, !idleEyeActive else { return }
        let actions = [blink, blink, lookAround, sway, yawn] // blink 权重高些,最自然
        actions.randomElement()?()
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

    @objc private func testWeChatNotificationHint(_ sender: Any?) {
        showWeChatNotificationHint(message: "微信来消息了")
    }

    @objc private func testLarkNotificationHint(_ sender: Any?) {
        flashNotice("飞书来消息了", accent: Self.larkAccent)
    }

    @objc private func testTaskDoneHint(_ sender: Any?) {
        // 演示带任务简介的自适应横幅:长任务会自动换行加高
        showTaskDoneHint(message: "Claude · 把登录模块重构成 async/await 并补全单元测试和错误处理")
    }

    // 临时诊断:把 Dock 与微信辅助功能树的真实字段 dump 到 /tmp/claudepet.log,取证后移除
    @objc private func exportWeChatDiagnostics(_ sender: Any?) {
        Self.dumpWeChatAccessibilityTree()
        showWeChatNotificationHint(message: "已导出探测详情")
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
        let scriptURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("claudepet-feed-\(UUID().uuidString).command")
        do {
            try feedScript(for: url, tool: tool).write(to: scriptURL, atomically: true, encoding: .utf8)
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
        case .claude: return ["cc"]
        case .codex:  return ["cx"]
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
}

// MARK: - 应用代理
@MainActor
final class SettingsWindowController: NSWindowController {
    private let valueLabel = NSTextField(labelWithString: "")
    private let colorTitle = NSTextField(labelWithString: "手动颜色")
    private let colorWell = NSColorWell(frame: .zero)
    private let autoAdaptButton = NSButton(checkboxWithTitle: "自动适应环境", target: nil, action: nil)
    private let weChatNotificationsButton = NSButton(checkboxWithTitle: "接收微信", target: nil, action: nil)
    private let larkNotificationsButton = NSButton(checkboxWithTitle: "接收飞书", target: nil, action: nil)
    private let taskDoneNotificationsButton = NSButton(checkboxWithTitle: "任务完成提示", target: nil, action: nil)
    private let slider = NSSlider(value: Settings.pounceDuration,
                                  minValue: Settings.minPounceDuration,
                                  maxValue: Settings.maxPounceDuration,
                                  target: nil,
                                  action: nil)

    init() {
        let content = NSView(frame: NSRect(x: 0, y: 0, width: 320, height: 320))
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
        buildContent(in: content)
        updateValueLabel()
        colorWell.color = Settings.petColor
        updateColorControls()
        updateWeChatControls()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("不支持 Interface Builder 加载") }

    private func buildContent(in content: NSView) {
        let title = NSTextField(labelWithString: "移动速度")
        title.font = .systemFont(ofSize: 15, weight: .semibold)
        title.frame = NSRect(x: 24, y: 278, width: 120, height: 22)
        content.addSubview(title)

        valueLabel.alignment = .right
        valueLabel.frame = NSRect(x: 180, y: 278, width: 116, height: 22)
        content.addSubview(valueLabel)

        slider.target = self
        slider.action = #selector(sliderChanged(_:))
        slider.numberOfTickMarks = 6
        slider.allowsTickMarkValuesOnly = false
        slider.frame = NSRect(x: 24, y: 240, width: 272, height: 24)
        content.addSubview(slider)

        let fast = NSTextField(labelWithString: "快")
        fast.textColor = .secondaryLabelColor
        fast.frame = NSRect(x: 24, y: 214, width: 40, height: 18)
        content.addSubview(fast)

        let slow = NSTextField(labelWithString: "慢")
        slow.textColor = .secondaryLabelColor
        slow.alignment = .right
        slow.frame = NSRect(x: 256, y: 214, width: 40, height: 18)
        content.addSubview(slow)

        colorTitle.font = .systemFont(ofSize: 15, weight: .semibold)
        colorTitle.frame = NSRect(x: 24, y: 176, width: 100, height: 22)
        content.addSubview(colorTitle)

        colorWell.target = self
        colorWell.action = #selector(colorChanged(_:))
        colorWell.frame = NSRect(x: 248, y: 170, width: 48, height: 32)
        content.addSubview(colorWell)

        autoAdaptButton.target = self
        autoAdaptButton.action = #selector(autoAdaptChanged(_:))
        autoAdaptButton.frame = NSRect(x: 24, y: 134, width: 160, height: 24)
        content.addSubview(autoAdaptButton)

        weChatNotificationsButton.target = self
        weChatNotificationsButton.action = #selector(weChatNotificationsChanged(_:))
        weChatNotificationsButton.frame = NSRect(x: 24, y: 96, width: 130, height: 24)
        content.addSubview(weChatNotificationsButton)

        larkNotificationsButton.target = self
        larkNotificationsButton.action = #selector(larkNotificationsChanged(_:))
        larkNotificationsButton.frame = NSRect(x: 168, y: 96, width: 130, height: 24)
        content.addSubview(larkNotificationsButton)

        taskDoneNotificationsButton.target = self
        taskDoneNotificationsButton.action = #selector(taskDoneNotificationsChanged(_:))
        taskDoneNotificationsButton.frame = NSRect(x: 24, y: 58, width: 200, height: 24)
        content.addSubview(taskDoneNotificationsButton)

        let close = NSButton(title: "关闭", target: self, action: #selector(closeWindow(_:)))
        close.bezelStyle = .rounded
        close.frame = NSRect(x: 218, y: 18, width: 78, height: 28)
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

    @objc private func closeWindow(_ sender: Any?) {
        close()
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
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var window: NSWindow!
    private weak var petView: PetView?
    private var settingsWindowController: SettingsWindowController?
    /// 任务完成提示节流:记下每个(工具+目录)上次弹的时间,窗口内重复来的直接跳过,免得连答几轮时连珠炮
    private var lastTaskDoneAt: [String: Date] = [:]
    private static let taskDoneThrottle: TimeInterval = 8

    func applicationDidFinishLaunching(_ notification: Notification) {
        PetView.log("ClaudePet 启动 feed-script-v2")
        let appSize = Style.canvasSize
        let screen = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        // 默认安静地待在屏幕右下角
        let origin = NSPoint(x: screen.maxX - appSize.width - 40, y: screen.minY + 40)

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
        PetView.log("热键注册 ⌥⌘C(claude)=\(okClaude) ⌥⌘X(codex)=\(okCodex)")
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
        let action = url.host ?? components?.host ?? ""
        guard action == "done" else { return }   // 目前只有 done 一种动作,host 留作未来扩展
        guard Settings.receiveTaskDoneNotifications else {   // 设置里关掉就不打扰,直接忽略
            PetView.log("任务完成提示已关闭,忽略 \(url.absoluteString)")
            return
        }
        let items = components?.queryItems ?? []
        let tool = items.first { $0.name == "tool" }?.value ?? ""
        let cwd = items.first { $0.name == "cwd" || $0.name == "dir" }?.value
        let task = items.first { $0.name == "task" }?.value
        // 节流:同一(工具+目录)在 taskDoneThrottle 秒内只弹一次,连答多轮不连珠炮
        let throttleKey = "\(tool)|\(cwd ?? "")"
        let now = Date()
        if let last = lastTaskDoneAt[throttleKey], now.timeIntervalSince(last) < AppDelegate.taskDoneThrottle {
            PetView.log("任务完成提示节流(\(Int(AppDelegate.taskDoneThrottle))s 内重复),跳过 \(url.absoluteString)")
            return
        }
        lastTaskDoneAt[throttleKey] = now
        let message = AppDelegate.taskDoneMessage(tool: tool, cwd: cwd, task: task)
        PetView.log("收到完成通知 \(url.absoluteString) → \(message)")
        petView?.showTaskDoneHint(message: message)
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
}

// MARK: - 离屏渲染自测
// 不依赖屏幕、不触碰桌面隐私,把一帧图标渲染成 PNG,供本地核对外观。
@MainActor
private func renderSnapshot(to path: String, mouthOpen: CGFloat = 0, eyeLook: CGVector = CGVector(dx: 0, dy: 0), eyeMode: PetView.EyeMode = .normal, runPhase: Int = 0) {
    let dim: CGFloat = 256
    let view = PetView(frame: NSRect(x: 0, y: 0, width: dim, height: dim))
    view.prepareSnapshot(withBackground: true, mouthOpen: mouthOpen, eyeLook: eyeLook, eyeMode: eyeMode, runPhase: runPhase)

    let image = NSImage(size: NSSize(width: dim, height: dim))
    image.lockFocus()
    view.draw(view.bounds)
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

    if let idx = arguments.firstIndex(of: "--feed-dryrun") {
        // 自测模式:打印投喂脚本(不执行),核对路径转义与命令拼装
        // 用法:--feed-dryrun <路径> [claude|codex],默认 claude
        let path = idx + 1 < arguments.count ? arguments[idx + 1] : "/tmp"
        let tool: FeedTool = (idx + 2 < arguments.count && arguments[idx + 2] == "codex") ? .codex : .claude
        print(PetView.feedScript(for: URL(fileURLWithPath: path), tool: tool))
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
        print("scheme=\(url.scheme ?? "(无)") action=\(url.host ?? components?.host ?? "(无)")")
        print("tool=\(tool.isEmpty ? "(空)" : tool) cwd=\(cwd ?? "(无)") task=\(task ?? "(无)")")
        print("横幅文案:\(AppDelegate.taskDoneMessage(tool: tool, cwd: cwd, task: task))")
        exit(0)
    }

    let app = NSApplication.shared
    app.setActivationPolicy(.accessory) // 不占 Dock、不抢焦点,等价 LSUIElement
    let delegate = AppDelegate()
    app.delegate = delegate
    app.run()
}
