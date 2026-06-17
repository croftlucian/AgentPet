import AppKit
import Carbon.HIToolbox // RegisterEventHotKey 等:注册全局快捷键,无需辅助功能权限

// MARK: - 外观与动画参数
// 集中放置便于调校,避免散落在各处的“魔法数字”
private enum Style {
    /// Claude 标志性赤陶橙 (#D97757),星芒主色
    static let orange = NSColor(srgbRed: 0xD9 / 255.0, green: 0x77 / 255.0, blue: 0x57 / 255.0, alpha: 1.0)
    /// 张嘴时口腔暗色,压在橙色花瓣上凸显“嘴”
    static let mouth = NSColor(srgbRed: 0x5A / 255.0, green: 0x2A / 255.0, blue: 0x1C / 255.0, alpha: 1.0)
    /// 呼吸完整周期(秒):一次缩放的吸→呼
    static let breathPeriod: Double = 6
    /// 窗口边长(点)
    static let windowSize: CGFloat = 90
}

// MARK: - 宠物视图
// 按终端象限网格自绘 Claude 星芒(还原 Claude Code 欢迎界面的方块星芒),
// 交给 Core Animation 做安静的“呼吸”缩放;draw(_:) 仅供离屏快照,运行时由图层显示。
final class PetView: NSView {
    /// 离屏快照模式:为透明背景铺深色底,便于肉眼/AI 核对渲染效果
    private var snapshotBackground = false
    /// 离屏快照时的张嘴幅度(0=闭嘴),便于自测渲染“吃”的一帧
    private var snapshotMouthOpen: CGFloat = 0
    /// 承载星星图标并接受呼吸动画的图层
    private let iconLayer = CALayer()
    /// 预渲染的两帧:闭嘴(常态)与张嘴(进食),拖放时在二者间切换出“咀嚼”
    private var closedFrame: CGImage?
    private var openFrame: CGImage?
    /// 咀嚼定时器(.common 模式,确保拖放进行中仍触发)与当前嘴态
    private var chewTimer: Timer?
    private var mouthIsOpen = false
    /// 快捷键投喂的"一口"收尾计时:拖放靠松手/离开收尾,快捷键没有拖放过程,故定时自动闭嘴
    private var biteTimer: Timer?
    /// 扑食动作进行中标志:防连按时把"归位坐标"记成动画途中的中间值
    private var isPouncing = false

    /// Claude 星芒的方块拼图(取自 Claude Code 欢迎界面),逐字符按象限自绘,严丝合缝
    private static let starArt = [
        " ▐▛███▜▌",
        "▝▜█████▛▘",
        "  ▘▘ ▝▝",
    ]

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.masksToBounds = false
        setupIconLayer(scale: NSScreen.main?.backingScaleFactor ?? 2)
        registerForDraggedTypes([.fileURL]) // 接住拖入的文件,投喂给 claude 分析
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("不支持 Interface Builder 加载") }

    // MARK: 图层装配
    private func setupIconLayer(scale: CGFloat) {
        iconLayer.frame = bounds
        iconLayer.anchorPoint = CGPoint(x: 0.5, y: 0.5) // 绕中心缩放
        iconLayer.position = CGPoint(x: bounds.midX, y: bounds.midY)
        iconLayer.contentsGravity = .resizeAspect // 保持图标比例
        iconLayer.contentsScale = scale
        // 预渲染常态/进食两帧,拖放时无需实时绘制即可切换
        closedFrame = Self.starImage(size: bounds.size).cgImage(forProposedRect: nil, context: nil, hints: nil)
        openFrame = Self.starImage(size: bounds.size, mouthOpen: 1).cgImage(forProposedRect: nil, context: nil, hints: nil)
        iconLayer.contents = closedFrame
        layer?.addSublayer(iconLayer)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard let window else { return }
        iconLayer.contentsScale = window.backingScaleFactor // 适配真实屏幕缩放,保证清晰
        startAnimations()
    }

    // MARK: 动画(交给 Core Animation,无需逐帧重绘)
    private func startAnimations() {
        guard iconLayer.animation(forKey: "breathe") == nil else { return }
        // 呼吸:在 0.95 ~ 1.0 间缓入缓出地缩放,幅度小、节奏慢,安静不抢眼
        let breathe = CABasicAnimation(keyPath: "transform.scale")
        breathe.fromValue = 0.95
        breathe.toValue = 1.0
        breathe.duration = Style.breathPeriod / 2
        breathe.autoreverses = true
        breathe.repeatCount = .infinity
        breathe.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        iconLayer.add(breathe, forKey: "breathe")
    }

    // MARK: 进食动画:拖入文件时张嘴咀嚼,离开/吃下即闭嘴
    // 用 Timer(.common 模式)手动切帧:拖放期间 runloop 处于 eventTracking,
    // 普通定时器与部分隐式动画不会触发,.common 才能保证“嚼”起来。
    private func startEating() {
        Self.log("startEating closed=\(closedFrame != nil) open=\(openFrame != nil)")
        guard chewTimer == nil else { return }
        mouthIsOpen = true
        setFrame(openFrame)                              // 立即张嘴,给即时反馈
        let timer = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.mouthIsOpen.toggle()
            self.setFrame(self.mouthIsOpen ? self.openFrame : self.closedFrame)
        }
        RunLoop.main.add(timer, forMode: .common)
        chewTimer = timer
    }

    private func stopEating() {
        chewTimer?.invalidate()
        chewTimer = nil
        setFrame(closedFrame)                            // 复位到闭嘴常态
    }

    // MARK: 快捷键投喂:原地"吃一口"
    // 没有拖放过程,故张嘴咀嚼一阵后用定时器自动闭嘴收尾;连按则顺延收尾,不会半路停。
    func eatBite() {
        setFeedGlow(true)
        startEating()                                    // 已在嚼则内部 guard 忽略,不重启
        biteTimer?.invalidate()                          // 重置收尾计时,支持连按顺延
        let timer = Timer(timeInterval: 1.0, repeats: false) { [weak self] _ in
            self?.stopEating()
            self?.setFeedGlow(false)
            self?.biteTimer = nil
        }
        RunLoop.main.add(timer, forMode: .common)
        biteTimer = timer
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
        let target = NSPoint(x: mouse.x - size.width / 2,  // 窗口中心对准光标
                             y: mouse.y - size.height / 2)
        Self.log("扑食 mouse=\(NSStringFromPoint(mouse)) home=\(NSStringFromPoint(home)) target=\(NSStringFromPoint(target))")

        slideWindow(window, from: home, to: target, duration: 0.35) { [weak self] in
            self?.eatBite()                                // 到位:张嘴嚼一口
            let back = Timer(timeInterval: 0.9, repeats: false) { [weak self] _ in
                self?.slideWindow(window, from: target, to: home, duration: 0.35) {
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
        let steps = max(1, Int(duration * 60))             // 约 60fps
        var i = 0
        let timer = Timer(timeInterval: duration / Double(steps), repeats: true) { t in
            i += 1
            let p = Double(i) / Double(steps)
            let e = p * p * (3 - 2 * p)                     // smoothstep:缓入缓出
            window.setFrameOrigin(NSPoint(x: from.x + (to.x - from.x) * CGFloat(e),
                                          y: from.y + (to.y - from.y) * CGFloat(e)))
            if i >= steps { t.invalidate(); then() }
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
    func prepareSnapshot(withBackground: Bool, mouthOpen: CGFloat = 0) {
        snapshotBackground = withBackground
        snapshotMouthOpen = mouthOpen
    }

    // MARK: 绘制(仅离屏快照走此路径;运行时由图层显示)
    override func draw(_ dirtyRect: NSRect) {
        if snapshotBackground, let ctx = NSGraphicsContext.current?.cgContext {
            ctx.setFillColor(NSColor(srgbRed: 0x1E / 255.0, green: 0x1E / 255.0, blue: 0x1E / 255.0, alpha: 1).cgColor)
            ctx.fill(bounds)
        }
        Self.starImage(size: bounds.size, mouthOpen: snapshotMouthOpen).draw(in: bounds) // NSImage 自动处理坐标翻转
    }

    // MARK: 星星图标渲染
    /// 把 starArt 的方块字符逐个按 2×2 象限自绘成星芒:不走字体、直接填充矩形,
    /// 故无字体拼接缝隙,能严丝合缝还原终端里的样子;cell 取瘦高比例,呼应终端字符格。
    private static func starImage(size: CGSize, mouthOpen: CGFloat = 0) -> NSImage {
        let image = NSImage(size: size)
        image.lockFocus()
        defer { image.unlockFocus() }
        guard let ctx = NSGraphicsContext.current?.cgContext else { return image }

        let rowCount = starArt.count
        let colCount = starArt.map(\.count).max() ?? 1
        let aspect: CGFloat = 2.0                       // cell 高/宽,模拟终端瘦高字符格
        let fill: CGFloat = 0.52                        // 网格占窗口比例:小巧居中又能看清表情
        let cellW = min(size.width * fill / CGFloat(colCount),
                        size.height * fill / (CGFloat(rowCount) * aspect))
        let cellH = cellW * aspect
        let originX = (size.width - cellW * CGFloat(colCount)) / 2
        let originY = (size.height - cellH * CGFloat(rowCount)) / 2

        ctx.setFillColor(Style.orange.cgColor)
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
        menu.addItem(NSMenuItem(title: "退出", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        return menu
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

    /// 拖入时点亮橙色光晕,松手/离开即熄灭;借图层阴影实现,不与呼吸缩放打架
    private func setFeedGlow(_ on: Bool) {
        iconLayer.shadowColor = Style.orange.cgColor
        iconLayer.shadowRadius = 12
        iconLayer.shadowOffset = .zero
        iconLayer.shadowOpacity = on ? 0.9 : 0
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
        # ClaudePet feed script v3: codex 快捷键固定调用 cx
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

    /// 终端 PATH 里依次尝试的命令名;⌥⌘X 按主公要求固定调用 cx,不兜底 codex。
    var commands: [String] {
        switch self {
        case .claude: return ["claude"]
        case .codex:  return ["cx"]
        }
    }

    /// PATH 找不到时尝试的常见绝对路径(Homebrew arm64 与 Intel 前缀)。
    func fallbackPaths(relativeTo appBundleURL: URL) -> [String] {
        switch self {
        case .claude:
            return ["/opt/homebrew/bin/claude", "/usr/local/bin/claude"]
        case .codex:
            let bundledCx = appBundleURL
                .appendingPathComponent("Contents")
                .appendingPathComponent("Resources")
                .appendingPathComponent("cx")
                .path
            return ["/opt/homebrew/bin/cx", "/usr/local/bin/cx", bundledCx]
        }
    }
    /// 日志/提示用名
    var label: String { commands.joined(separator: "/") }
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
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var window: NSWindow!

    func applicationDidFinishLaunching(_ notification: Notification) {
        PetView.log("ClaudePet 启动 feed-script-v2")
        let size = Style.windowSize
        let screen = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        // 默认安静地待在屏幕右下角
        let origin = NSPoint(x: screen.maxX - size - 40, y: screen.minY + 40)

        let win = NSWindow(
            contentRect: NSRect(origin: origin, size: CGSize(width: size, height: size)),
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        win.isOpaque = false
        win.backgroundColor = .clear
        win.hasShadow = true // 圆角方块图标投下自然阴影,像停在桌面上
        win.level = .floating // 浮在普通窗口之上
        // 跨所有桌面/空间显示,并能浮在全屏应用之上
        win.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        win.isMovableByWindowBackground = true // 整窗可拖拽
        let petView = PetView(frame: NSRect(origin: .zero, size: CGSize(width: size, height: size)))
        win.contentView = petView
        win.makeKeyAndOrderFront(nil)
        window = win

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
}

// MARK: - 离屏渲染自测
// 不依赖屏幕、不触碰桌面隐私,把一帧图标渲染成 PNG,供本地核对外观。
@MainActor
private func renderSnapshot(to path: String, mouthOpen: CGFloat = 0) {
    let dim: CGFloat = 256
    let view = PetView(frame: NSRect(x: 0, y: 0, width: dim, height: dim))
    view.prepareSnapshot(withBackground: true, mouthOpen: mouthOpen)

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

    let app = NSApplication.shared
    app.setActivationPolicy(.accessory) // 不占 Dock、不抢焦点,等价 LSUIElement
    let delegate = AppDelegate()
    app.delegate = delegate
    app.run()
}
