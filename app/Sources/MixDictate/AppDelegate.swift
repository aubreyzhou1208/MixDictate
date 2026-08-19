import AppKit
import AVFoundation

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var monitor: HotKeyMonitor?
    private let hotwordCandidatesWindow = HotwordCandidatesWindowController()
    private lazy var corrections = CorrectionWatcher(config: config)

    /// 录音/转写期间盯着 Esc 的两个监听。全局的管别的 App 在前台的情况，
    /// 本地的管我们自己的窗口在前台的情况 —— 少一个就会有一半场景按了没用。
    private var escapeMonitor: Any?
    private var localEscapeMonitor: Any?

    /// 每次听写一个编号。取消时 +1，在飞的请求回来发现编号变了就丢弃 ——
    /// 不这样的话，取消之后一两秒，那句话还是会自己蹦进输入框。
    private var sessionID = 0

    /// 最近一次听写录到的最大响度。写进状态文件给 verify.sh 看 ——
    /// "采集是不是全零"这件事骗过我好几轮，必须变成一个能从终端读到的数字。
    private var lastCapturePeak: Float = -1

    /// 最近一次听写被人声门限写成静音的时长。门限吃字这件事以前完全
    /// 看不见 —— 只表现成"句子里少了几个字"，必须变成一个能读到的数字。
    private var lastGatedSeconds: Double = -1
    private let recorder = AudioRecorder()
    private var config = Config.load()
    private var server: ServerProcess!
    private let settingsWindow = SettingsWindowController()
    private let overlay = OverlayWindow()
    private let liveInserter = LiveInserter()
    private var partialTimer: Timer?
    /// 同一时刻只允许一个中间请求在飞。模型是串行的，堆积请求
    /// 只会让松手后的最终结果排在后面等更久。
    private var partialInFlight = false
    private var permissionTimer: Timer?
    private var configTimer: Timer?
    private var configStamp: Date?
    /// 已定稿段落拼起来的文字。这部分不会再被重新转写。
    private var committedText = ""
    /// 未定稿那一段的最新转写，以及它对应的音频结束位置
    private var pendingText = ""
    /// 连续多少次检测到静音。第一次检测时用户往往还没开口，
    /// 立刻报「没有听到声音」是误报。
    private var silentTicks = 0
    private var lastError: String?

    private enum State {
        case launching, idle, recording, transcribing, failed
    }

    private var state: State = .launching {
        didSet { refreshStatusItem() }
    }

    // MARK: - 生命周期

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        buildMenu()
        refreshStatusItem()

        requestMicrophoneAccess()
        checkAccessibilityOrWait()

        server = ServerProcess(config: config)
        Task { @MainActor in await startServer() }

        installHotKeyMonitor()
        startConfigWatch()
        writeStatusFile()

        // "它自己改了我的词表"这件事必须让人看见。学到的时候浮层说一声，
        // 不然词表会在用户不知情的情况下长出新规则。
        corrections.onLearned = { [weak self] wrong, right in
            guard let self else { return }
            overlay.show(style: .compact, status: "学会了")
            overlay.update("以后「\(wrong)」自动改成「\(right)」", isFinal: true)
            overlay.hide(after: 3)
        }
    }

    // MARK: - 给终端看的状态文件

    /// 把 App 自己的内部状态写到磁盘上，让 doctor.sh 能读到。
    ///
    /// 「按 Option 完全没反应」这件事在终端里是彻底不可见的：辅助功能权限有没有、
    /// 监听装没装上、监听的是哪个键、App 还活着没有 —— 这些只有 App 自己知道，
    /// 而它偏偏是个连窗口都没有的菜单栏程序。没有这份文件就只能靠猜，
    /// 而我已经猜错过好几次了。
    ///
    /// 文件的**修改时间**本身也是信息：过期了就说明 App 根本没在跑。
    private func writeStatusFile() {
        let micStatus: String
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: micStatus = "authorized"
        case .denied: micStatus = "denied"
        case .restricted: micStatus = "restricted"
        case .notDetermined: micStatus = "notDetermined"
        @unknown default: micStatus = "unknown"
        }

        let payload: [String: Any] = [
            "pid": ProcessInfo.processInfo.processIdentifier,
            "accessibility": TextInjector.hasAccessibilityPermission,
            "microphone": micStatus,
            "hotkeyKeyCode": Int(config.pushToTalkKeyCode),
            "hotkeyName": HotKeyMonitor.displayName(for: config.pushToTalkKeyCode),
            "hotkeyMonitorInstalled": monitor != nil,
            "echoCancellation": recorder.echoCancellationActive,
            "inputFormat": recorder.inputFormatDescription,
            "lastCapturePeak": lastCapturePeak,
            "lastGatedSeconds": lastGatedSeconds,
            "state": String(describing: state),
            "lastError": lastError ?? "",
            "appPath": Bundle.main.bundleURL.path,
        ]

        guard let data = try? JSONSerialization.data(
            withJSONObject: payload, options: [.prettyPrinted, .sortedKeys]
        ) else { return }

        let url = ServerProcess.supportDirectory
            .appendingPathComponent("logs/app_status.json")
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try? data.write(to: url, options: .atomic)
    }

    // MARK: - 配置热加载

    /// 盯着配置文件的修改时间。命令行改完要能立刻生效 ——
    /// 菜单栏图标经常被刘海挤掉找不到，而 Cmd+, 对菜单栏 App 不响应，
    /// 命令行是很多人唯一能用的入口。
    private func startConfigWatch() {
        configStamp = Config.modificationDate()
        configTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in self.reloadConfigIfChanged() }
        }
    }

    private func reloadConfigIfChanged() {
        // 每次心跳都刷一遍：内容基本不变，但修改时间会更新 ——
        // doctor.sh 靠它判断 App 是不是还活着
        writeStatusFile()

        // 录音中途换配置只会制造混乱，等空闲了再说
        guard state == .idle || state == .failed else { return }

        let stamp = Config.modificationDate()
        guard stamp != configStamp else { return }
        configStamp = stamp

        let previousKey = config.pushToTalkKeyCode
        let previousModel = config.model
        config = Config.load()

        if config.pushToTalkKeyCode != previousKey {
            installHotKeyMonitor()
        }
        buildMenu()
        NSLog("MixDictate: 配置已重新加载")

        if config.model != previousModel {
            restartServer()
        }
    }

    // MARK: - 辅助功能权限

    /// 全局按键监听（addGlobalMonitorForEvents）本身就需要辅助功能权限。
    /// 没有它，说话键的按下事件根本传不到 App —— 不是转写失败，而是整个
    /// 流程压根不启动，用户看到的是「按了完全没反应」。
    ///
    /// 所以权限缺失必须当成硬故障，而不是启动时弹一次系统对话框就算了：
    /// 用户关掉那个对话框之后，App 会一直装作一切正常。
    private func checkAccessibilityOrWait() {
        if TextInjector.hasAccessibilityPermission {
            permissionTimer?.invalidate()
            permissionTimer = nil
            return
        }

        TextInjector.ensureAccessibilityPermission(prompt: true)
        fail("缺少「辅助功能」权限 —— 说话键收不到任何按键")
        startPermissionWatch()
    }

    /// 用户去系统设置里打开开关后，App 要能自己发现并恢复。
    /// 让用户手动重启 App 是很差的体验，而且他们根本不会知道要这么做。
    private func startPermissionWatch() {
        guard permissionTimer == nil else { return }
        permissionTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in self.onPermissionTick() }
        }
    }

    private func onPermissionTick() {
        guard TextInjector.hasAccessibilityPermission else { return }

        permissionTimer?.invalidate()
        permissionTimer = nil
        lastError = nil

        // 权限是在监听装好之后才拿到的，必须重装一次才会真正生效
        installHotKeyMonitor()
        buildMenu()
        state = .idle
        writeStatusFile()

        let alert = NSAlert()
        alert.messageText = "辅助功能权限已生效"
        let key = HotKeyMonitor.displayName(for: config.pushToTalkKeyCode)
        alert.informativeText = "现在按住 \(key) 就可以说话了。"
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    /// 重新触发系统的授权对话框。
    ///
    /// 需要这个入口是因为：权限按代码签名记录，而每次重新构建都是 ad-hoc
    /// 签名，重装几次之后 TCC 里的旧记录会跟新签名对不上 —— 列表里看不到
    /// 这个 App，或者看到了勾上也不生效。这时候只能清空 TCC 记录重来。
    @objc private func requestAccessibilityAgain() {
        if TextInjector.hasAccessibilityPermission {
            let ok = NSAlert()
            ok.messageText = "辅助功能权限已经有了"
            ok.informativeText = "如果按住说话键仍然没反应，请把菜单里「查看服务日志…」的内容发出来。"
            NSApp.activate(ignoringOtherApps: true)
            ok.runModal()
            return
        }

        TextInjector.ensureAccessibilityPermission(prompt: true)
        startPermissionWatch()

        let alert = NSAlert()
        alert.messageText = "请在系统设置里打开 MixDictate"
        alert.informativeText = """
            系统设置 › 隐私与安全性 › 辅助功能

            列表里找不到它，或者打开了也不管用？
            在「终端」里运行下面三行，然后重新授权：

              tccutil reset Accessibility dev.mixdictate.app
              pkill -x MixDictate
              open -a MixDictate
            """
        alert.addButton(withTitle: "打开设置")
        alert.addButton(withTitle: "复制上面的命令")
        alert.addButton(withTitle: "关闭")

        NSApp.activate(ignoringOtherApps: true)
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            SystemSettings.openAccessibility()
        case .alertSecondButtonReturn:
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.setString(
                "tccutil reset Accessibility dev.mixdictate.app\n"
                    + "pkill -x MixDictate\n"
                    + "open -a MixDictate\n",
                forType: .string
            )
        default:
            break
        }
    }

    private func installHotKeyMonitor() {
        monitor?.stop()
        monitor = HotKeyMonitor(
            keyCode: config.pushToTalkKeyCode,
            onPress: { [weak self] in self?.beginRecording() },
            onRelease: { [weak self] in self?.endRecording() }
        )
        monitor?.start()
    }

    // MARK: - 设置

    @objc private func openSettings() {
        settingsWindow.show(config: config) { [weak self] updated, modelChanged in
            guard let self else { return }
            self.config = updated

            // 说话键立刻生效：把旧监听拆掉换新的
            self.installHotKeyMonitor()
            self.buildMenu()

            // 模型是启动参数，只能重启服务
            if modelChanged {
                self.restartServer()
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        stopEscapeWatch()
        monitor?.stop()
        stopPartialUpdates()
        permissionTimer?.invalidate()
        configTimer?.invalidate()
        server?.stop()
    }

    // MARK: - 转写服务

    private func startServer() async {
        state = .launching
        switch await server.start() {
        case .ready:
            // 权限缺失是更严重的故障，服务就绪不该把它的提示盖掉
            if TextInjector.hasAccessibilityPermission {
                state = .idle
                lastError = nil
            }
            buildMenu()
        case .failed(let message):
            fail(message)
        case .stopped, .starting:
            fail("服务状态异常")
        }
    }

    @objc func restartServer() {
        server.stop()
        Task { @MainActor in await startServer() }
    }

    @objc private func openServerLog() {
        NSWorkspace.shared.open(ServerProcess.logURL)
    }

    /// 最近一次录音的原始音频。模型没输出时，先听一下这个 ——
    /// 能听清自己说话，问题就在模型或热词；听不清，问题在录音链路。
    @objc private func openLastRecording() {
        let url = ServerProcess.supportDirectory
            .appendingPathComponent("logs/last_request.wav")
        guard FileManager.default.fileExists(atPath: url.path) else {
            let alert = NSAlert()
            alert.messageText = "还没有录音文件"
            alert.informativeText = "先按住说话键说一句话，松开后再回来看。"
            NSApp.activate(ignoringOtherApps: true)
            alert.runModal()
            return
        }
        NSWorkspace.shared.open(url)
    }

    /// 热词候选。**没有自动入表的路径** —— 词表是拿去偏置解码器的，
    /// 一个听错的词进了表会让模型把这个错误听得更稳定，那比不加还糟。
    /// 所以只提供候选，勾选和「加入」必须是人做的动作。
    @objc private func openHotwordCandidates() {
        hotwordCandidatesWindow.show(config: config)
    }

    // MARK: - 人声门限校准

    /// 量一下「外放漏进麦克风」和「你说话」到底差多少。
    ///
    /// 这个门限没法靠猜：它取决于机器、麦克风位置、扬声器音量、房间。
    /// 让人对着一个 0…0.3 的滑块试错，等于让他在黑暗里调焦。
    ///
    /// 量两次就有数了，而且量完还能回答一个更要紧的问题：这两者到底
    /// 分不分得开。分不开的话调什么门限都没用 —— 那时候该说的是
    /// 「戴耳机」，不是再给一个看起来很精确的数字。
    @objc private func calibrateThreshold() {
        guard state == .idle || state == .failed else {
            NSSound.beep()
            return
        }

        NSApp.activate(ignoringOtherApps: true)
        let intro = NSAlert()
        intro.messageText = "校准人声门限"
        intro.informativeText = """
            分两步，各 4 秒。

            第 1 步：别说话，让视频照常放着。
            第 2 步：用平时的音量正常说一句话。

            点「开始」后立刻进入第 1 步。
            """
        intro.addButton(withTitle: "开始")
        intro.addButton(withTitle: "取消")
        guard intro.runModal() == .alertFirstButtonReturn else { return }

        Task { @MainActor in
            guard let noise = await measureLevel(status: "别说话…") else { return }

            NSApp.activate(ignoringOtherApps: true)
            let step2 = NSAlert()
            step2.messageText = String(format: "环境峰值 %.3f", noise)
            step2.informativeText = "第 2 步：点「开始」后正常说一句话，4 秒。"
            step2.addButton(withTitle: "开始")
            step2.addButton(withTitle: "取消")
            guard step2.runModal() == .alertFirstButtonReturn else { return }

            guard let voice = await measureLevel(status: "说句话…") else { return }
            showCalibrationResult(noise: noise, voice: voice)
        }
    }

    /// 关掉门限录一段，返回这段时间里的最大响度。
    ///
    /// 必须关掉门限。开着量到的是「过了门限的声音有多大」，
    /// 而这里要问的恰恰是「这声音够不够得着门限」。
    private func measureLevel(status: String) async -> Float? {
        do {
            recorder.voiceThreshold = 0
            recorder.maxPauseSeconds = 0
            try recorder.start(cancelEcho: config.echoCancellation)
        } catch {
            reportFailure(error)
            return nil
        }
        overlay.show(style: .compact, status: status)
        try? await Task.sleep(nanoseconds: 4_000_000_000)
        _ = recorder.stop(minimumDuration: 0)
        overlay.hide(after: 0)
        return recorder.loudestLevel
    }

    private func showCalibrationResult(noise: Float, voice: Float) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()

        // 差得不够开就别给建议。给一个夹在中间的数字会让人以为调好了，
        // 实际上要么继续漏、要么开始吞字 —— 比直说「分不开」糟糕得多。
        guard voice > noise * 1.6, voice > 0.02 else {
            alert.messageText = "这两者分不开"
            alert.informativeText = String(
                format: """
                    环境 %.3f，说话 %.3f —— 差距太小，没有哪个门限能只挡住一边。

                    多半是外放音量太大、麦克风离扬声器太近，\
                    或者第 2 步没说话、说得太轻。

                    最彻底的办法是戴耳机：声音根本不进麦克风，才是真的隔绝。
                    """,
                noise, voice
            )
            alert.runModal()
            return
        }

        // 取几何平均而不是算术平均：响度是个比例量。0.02 和 0.5 中间该是
        // 0.1，不是 0.26 —— 算术平均会紧紧贴着大的那一头，门限就偏高了。
        let base = max(Double(noise), 0.01)
        let suggested = min(0.3, max(0.01, (base * Double(voice)).squareRoot()))
        let rounded = (suggested * 100).rounded() / 100

        alert.messageText = String(format: "建议门限 %.2f", rounded)
        alert.informativeText = String(
            format: """
                环境噪声峰值 %.3f，你说话峰值 %.3f，相差 %.1f 倍。
                当前门限 %.2f。

                新门限落在两者中间：外放挡得住，你说话过得去。
                """,
            noise, voice, voice / max(noise, 0.001), config.voiceThreshold
        )
        alert.addButton(withTitle: String(format: "设为 %.2f", rounded))
        alert.addButton(withTitle: "不改")
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        config.voiceThreshold = rounded
        try? config.save()
    }

    /// 每次转写的原始输出和处理后结果。调准确率就看这个文件。
    @objc private func openTranscriptLog() {
        let url = ServerProcess.supportDirectory
            .appendingPathComponent("logs/transcripts.log")
        guard FileManager.default.fileExists(atPath: url.path) else {
            let alert = NSAlert()
            alert.messageText = "还没有转写记录"
            alert.informativeText = "先说几句话试试，记录会自动写到这里。"
            alert.runModal()
            return
        }
        NSWorkspace.shared.open(url)
    }

    // MARK: - 录音 → 转写 → 插入

    private func beginRecording() {
        if state == .launching {
            // 首次启动在加载模型（或下载模型），这时候按键没用，
            // 但不能默默吞掉 —— 用户会以为快捷键坏了
            NSSound.beep()
            return
        }
        guard state == .idle || state == .failed else { return }
        do {
            recorder.voiceThreshold = Float(max(0, min(1, config.voiceThreshold)))
            recorder.maxPauseSeconds = max(0, config.maxPauseSeconds)
            try recorder.start(cancelEcho: config.echoCancellation)
            sessionID += 1
            // 上一轮的观察还没到时间就作废：新一轮马上要往同一个输入框里写，
            // 再去比对上一段就会把两轮的内容混在一起
            corrections.cancel()
            startEscapeWatch()
            silentTicks = 0
            committedText = ""
            pendingText = ""
            liveInserter.reset()
            state = .recording
            // 按下的这一刻离真正的转写请求还有约 0.8 秒，正好用来把
            // Metal 计算核的编译开销提前付掉 —— 否则它会落在你的第一句话上。
            let client = TranscriptionClient(config: config)
            Task { await client.warmup() }

            // 实时写入模式下，小指示器是**唯一**的进行中反馈 —— 文字要过
            // 一两秒才出现，这期间用户完全不知道它有没有在工作。所以它不受
            // showLiveOverlay 控制：那个开关管的是显示全文的大浮层。
            if config.liveInsertion {
                overlay.show(style: .compact, status: "正在听写")
            } else if config.showLiveOverlay {
                overlay.show(style: .fullText, status: "听着呢…")
            }

            // 实时写入也要靠中间结果
            if config.showLiveOverlay || config.liveInsertion {
                startPartialUpdates()
            }
        } catch {
            fail("麦克风打不开：\(error.localizedDescription)")
        }
    }

    // MARK: - 中途取消

    /// 录音或转写期间按 Esc 取消。
    ///
    /// 中途反悔太常见了 —— 说错了、有人进来了、发现光标根本不在想要的
    /// 输入框里。在这之前唯一的出路是把话说完、等它写进去、再手动删掉。
    private func startEscapeWatch() {
        stopEscapeWatch()

        escapeMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) {
            [weak self] event in
            guard event.keyCode == 53 else { return }  // 53 = Esc
            guard let self else { return }
            Task { @MainActor in self.cancelDictation() }
        }

        // 设置窗口在前台时全局监听收不到事件，得再加一个本地的。
        // 返回 nil 把这次 Esc 吞掉：正在听写时它的含义就是"取消听写"。
        localEscapeMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) {
            [weak self] event in
            guard event.keyCode == 53, let self else { return event }
            Task { @MainActor in self.cancelDictation() }
            return nil
        }
    }

    private func stopEscapeWatch() {
        if let escapeMonitor { NSEvent.removeMonitor(escapeMonitor) }
        if let localEscapeMonitor { NSEvent.removeMonitor(localEscapeMonitor) }
        escapeMonitor = nil
        localEscapeMonitor = nil
    }

    private func cancelDictation() {
        guard state == .recording || state == .transcribing else { return }

        // 先让在飞的转写作废。取消之后过一秒那句话自己蹦出来，
        // 比不能取消更让人措手不及。
        sessionID += 1
        stopEscapeWatch()
        stopPartialUpdates()
        _ = recorder.stop(minimumDuration: 0)

        // 实时写入模式下已经打进去的字要撤掉 —— 取消却在输入框里留下
        // 半句话，等于没取消。
        if config.liveInsertion, !liveInserter.inserted.isEmpty {
            liveInserter.update(to: "")
        }
        liveInserter.reset()
        committedText = ""
        pendingText = ""

        // 立刻收掉，不留"已取消"那一下。
        //
        // 别的收场都会在屏幕上停一会儿，因为有东西要给人看：最终文字、
        // 错误原因。取消没有 —— 你已经知道自己按了 Esc，浮层再停 0.8 秒
        // 只是让"我不要了"这个动作看起来没生效。**消失本身就是确认。**
        overlay.hide(after: 0)
        state = .idle
    }

    // MARK: - 边说边转写

    /// 录音过程中定期把"到目前为止"的音频拿去转一遍，显示在浮层上。
    /// 每次都从头转整段而不是增量拼接 —— 模型是整段推理的，
    /// 分段拼接会在切口处丢字，中英混说时尤其明显。
    private func startPartialUpdates() {
        scheduleNextPartial()
    }

    /// 用一次性定时器不断重排，而不是固定周期重复 —— 因为间隔是变的。
    private func scheduleNextPartial() {
        guard state == .recording else { return }

        partialTimer?.invalidate()
        partialTimer = Timer.scheduledTimer(
            withTimeInterval: nextPartialDelay(),
            repeats: false
        ) { [weak self] _ in
            // 先解包成不可变的 self 再进 Task —— [weak self] 捕获出来的是
            // 可变的可选变量，Swift 不允许在并发上下文里直接引用它
            guard let self else { return }
            Task { @MainActor in
                self.requestPartial()
                self.scheduleNextPartial()
            }
        }
    }

    /// 每次中间结果都要重转**整段**音频，所以录得越久单次开销越大。
    /// 固定 1.2 秒的话，说 10 秒累计要转掉约 45 秒的音频 —— 是最终那次
    /// 的 4.5 倍，GPU 全被中间请求占着，松手后的结果反而要排队。
    /// 让间隔跟着已录时长增长，把额外开销压在可控范围内。
    private func nextPartialDelay() -> TimeInterval {
        // 按**未定稿段落**的长度算，不是总时长 —— 单次推理的开销只跟
        // 这一段有关，而段落长度已经封顶（8 秒），所以间隔也能封得更低。
        let scaled = recorder.pendingSeconds * 0.3
        return min(1.5, max(config.partialIntervalSeconds, scaled))
    }

    private func stopPartialUpdates() {
        partialTimer?.invalidate()
        partialTimer = nil
    }

    private func requestPartial() {
        guard state == .recording else { return }

        if recorder.consumePeakLevel() > 0.01 {
            silentTicks = 0
        } else if !recorder.heardSound {
            silentTicks += 1
            // 等两轮再报。按下到开口之间总有停顿，第一轮就报是误报 ——
            // 用户会以为麦克风坏了，其实只是他还没开始说。
            if silentTicks >= 2 {
                overlay.setStatus("没有听到声音")
                overlay.update("没有听到声音，检查一下麦克风权限和输入设备", isFinal: false)
            }
        }

        guard !partialInFlight, let snapshot = recorder.pendingSnapshot() else { return }

        partialInFlight = true
        let client = TranscriptionClient(config: config)
        let session = sessionID

        Task { @MainActor in
            defer { partialInFlight = false }

            let text: String
            do {
                text = try await client.transcribe(wav: snapshot.wav, partial: true)
            } catch {
                // 中间请求失败不打断录音，但要留下痕迹 —— 松手后的最终请求
                // 多半会因为同样的原因失败，到时候浮层会把它显示出来
                NSLog("MixDictate: 中间转写失败 %@", error.localizedDescription)
                return
            }
            // 请求飞在路上时用户可能已经松手了，这时别再盖掉最终结果。
            // 也可能按了 Esc 又开了新一轮，所以还要比对编号 ——
            // 光看状态的话，上一轮的中间结果会盖到这一轮头上。
            guard state == .recording, session == sessionID else { return }
            // 空结果别覆盖掉「没有听到声音」那条提示
            guard !text.isEmpty else { return }

            pendingText = text

            if let boundary = snapshot.boundary {
                // 这一段就此定稿 —— 之后不会再转写它。这是长录音不再越来越慢
                // 的关键：开销只跟"最后一段"有关，跟总时长无关。
                committedText += Self.joinable(text, at: boundary)
                pendingText = ""
                recorder.commit(upTo: snapshot.endOffset)
            }

            show(committedText + pendingText, isFinal: false)
        }
    }

    /// 把当前进展显示出来：写输入框还是写浮层
    private func show(_ text: String, isFinal: Bool) {
        if config.liveInsertion {
            liveInserter.update(to: text)
        } else {
            overlay.update(text, isFinal: isFinal)
        }
    }

    private func endRecording() {
        guard state == .recording else { return }
        stopPartialUpdates()
        stopEscapeWatch()
        lastCapturePeak = recorder.loudestLevel
        lastGatedSeconds = recorder.gatedSeconds
        writeStatusFile()

        guard let audio = recorder.stop(minimumDuration: config.minimumDurationSeconds) else {
            // 以前这里是静默返回的，结果就是「按了没反应」—— 用户完全无从
            // 判断是按太短了还是麦克风根本没工作。这两件事必须说清楚。
            let reason = recorder.heardSound
                ? "太短了，没录到内容"
                : silentCaptureMessage()
            overlay.setStatus(reason)
            overlay.update(reason, isFinal: true)
            overlay.hide(after: 1.6)
            state = .idle
            return
        }

        state = .transcribing
        overlay.setStatus("整理中…")
        overlay.update("整理中…", isFinal: false)
        let client = TranscriptionClient(config: config)

        // 短录音走完整音频重转一遍。分段是为了说话过程中的实时预览提速，
        // 代价是每段只看得到自己那两三秒 —— 上下文没了，识别会变差，
        // 段落边界的标点也只能靠猜。松手时重转一次就把这两样都补回来。
        //
        // 太长的录音不重转：那笔开销正是当初做分段要解决的问题。
        let totalSeconds = recorder.capturedSeconds
        let useFullPass = totalSeconds <= config.fullPassMaxSeconds

        // 记下这次听写的编号。等结果回来时如果编号变了，说明中途按了 Esc，
        // 这份结果就不该再落进输入框。
        let session = sessionID

        if useFullPass {
            Task { @MainActor in
                do {
                    let text = try await client.transcribe(wav: audio.full)
                    guard session == sessionID else { return }
                    guard !text.isEmpty else {
                        reportEmptyResult()
                        return
                    }
                    deliver(text)
                } catch {
                    guard session == sessionID else { return }
                    reportFailure(error)
                }
            }
            return
        }

        // 长录音：拼接已定稿的段落，只转最后那一段
        if audio.tail.isEmpty {
            deliver(committedText)
            return
        }

        // 这里原来有个"尾部没怎么长就直接复用最后一次中间结果"的捷径。
        // 删掉了：它省下的是一次推理，代价却是最后那 0.4 秒**永远不会被
        // 转写** —— 而 0.4 秒足够装下一个字。用户看到的就是"最后一个字
        // 有时候没有"。省一次推理换掉一个字，这笔交易不成立。

        Task { @MainActor in
            do {
                let tail = try await client.transcribe(wav: audio.tail)
                guard session == sessionID else { return }
                let text = committedText + tail
                guard !text.isEmpty else {
                    reportEmptyResult()
                    return
                }
                deliver(text)
            } catch {
                guard session == sessionID else { return }
                reportFailure(error)
            }
        }
    }

    private func reportEmptyResult() {
        let reason: String
        if !recorder.heardSound {
            reason = silentCaptureMessage()
        } else if config.voiceThreshold > 0,
                  Double(recorder.loudestLevel) < config.voiceThreshold {
            // 麦克风有信号，但全程没越过人声门限，整段都被当成环境音挡掉了。
            // 不说清楚的话，这跟「模型没听懂」看起来一模一样，
            // 而这两件事的解法完全相反。
            reason = String(
                format: "声音都低于人声门限（最大 %.2f，门限 %.2f），去设置里调低",
                recorder.loudestLevel, config.voiceThreshold
            )
        } else {
            reason = "没识别出内容"
        }
        overlay.setStatus(reason)
        overlay.update(reason, isFinal: true)
        overlay.hide(after: 1.6)
        state = .idle
    }

    private func reportFailure(_ error: Error) {
        // 错误必须显示在浮层上。只写进菜单栏图标是不够的 ——
        // 菜单栏图标多了会被刘海挤掉，用户根本看不见，
        // 于是转写失败在他眼里就成了「什么都没发生」。
        overlay.setStatus("出错了")
        overlay.update("出错了：\(error.localizedDescription)", isFinal: true)
        overlay.hide(after: 5)
        fail(error.localizedDescription)
    }

    /// 拼接用的段落文字：**一律去掉句末标点**。
    ///
    /// 上一版试过用停顿时长判断句子有没有说完 —— 停 2 秒以上就保留句号。
    /// 那个思路是错的：想词时停三秒和说完一句停三秒，从音频上分不出来。
    /// 用户的反馈很直接：「中间我停顿了一下，它就会自动给我加进来一个句号，
    /// 这个是我不想看到的」。
    ///
    /// 少一个该有的句号，用户补一下就行；多一个不该有的句号，是把他的
    /// 一句话劈成了两句。所以宁可不加。
    ///
    /// 真正的标点由松手后那次完整音频的推理给出 —— 那时模型看得到全文。
    private static func joinable(_ text: String, at boundary: AudioRecorder.Boundary) -> String {
        _ = boundary
        return strippingSentenceEnd(text)
    }

    private static func strippingSentenceEnd(_ text: String) -> String {
        var result = text
        while let last = result.last, "。！？，、.!?,".contains(last) {
            result.removeLast()
        }
        return result
    }

    /// 把最终文字送到该去的地方。两条路都会走到这里：正常转写完，
    /// 或者直接复用最后一次中间结果。
    private func deliver(_ text: String) {
        // 实时写入模式：文字早就在输入框里了，这里只要把它改成最终版本 ——
        // 不用再粘贴一次，那正是"还要再复制一遍"的慢感来源
        if config.liveInsertion {
            liveInserter.update(to: text)
            // 让指示器显示一下"完成"再消失，用户才知道这一轮结束了
            overlay.setStatus("完成")
            overlay.hide(after: 0.8)
            state = .idle
            corrections.noteInsertion(text)
            return
        }

        // 先把最终结果显示出来，用户能看到它跟中间结果差在哪
        overlay.update(text, isFinal: true)

        switch TextInjector.insert(text, method: config.resolvedInsertionMethod) {
        case .inserted(let method):
            NSLog("MixDictate: 已通过 %@ 插入", method.rawValue)
            overlay.hide(after: 1.2)
            corrections.noteInsertion(text)
        case .insertedViaAccessibility:
            // 安全输入模式挡住了合成按键，但辅助功能接口写进去了
            NSLog("MixDictate: 安全输入模式，已改走辅助功能接口")
            overlay.hide(after: 1.2)
            corrections.noteInsertion(text)
        case .needsAccessibility:
            overlay.hide()
            reportAccessibilityMissing()
        case .blockedBySecureInput:
            // 三条路都走不通。文字已经在剪贴板里了。
            overlay.update(
                "有 App 开着安全输入模式，自动输入被系统拦截。文字已复制，按 Cmd+V 粘贴",
                isFinal: true
            )
            overlay.hide(after: 5)
        }
        state = .idle
    }

    /// 缺辅助功能权限是"按了没反应"最常见的原因。给一个能直接跳到
    /// 设置页的弹窗，别让用户自己在系统设置里翻。
    private func reportAccessibilityMissing() {
        let alert = NSAlert()
        alert.messageText = "需要「辅助功能」权限才能自动输入"
        alert.informativeText = "文字已经复制到剪贴板，可以直接按 Cmd+V 粘贴。\n\n"
            + "要让 MixDictate 自动输入，请到\n"
            + "系统设置 › 隐私与安全性 › 辅助功能\n"
            + "里把 MixDictate 打开。"
        alert.addButton(withTitle: "打开设置")
        alert.addButton(withTitle: "稍后")
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn {
            SystemSettings.openAccessibility()
        }
    }

    private func fail(_ message: String) {
        lastError = message
        state = .failed
        buildMenu()
        NSLog("MixDictate: %@", message)
    }

    // MARK: - 麦克风

    /// 麦克风权限被拒时，macOS **不会报错** —— AVAudioEngine 照常启动、
    /// tap 照常回调，只是送来的样本全是零。所以"没录到声音"和"录到了静音"
    /// 在代码里长得一模一样，必须显式检查权限 + 显式检查音量，
    /// 否则用户看到的就是"浮层出来了但什么都不发生"。
    private func requestMicrophoneAccess() {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            break
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { [weak self] granted in
                guard !granted else { return }
                Task { @MainActor in self?.reportMicrophoneDenied() }
            }
        default:
            reportMicrophoneDenied()
        }
    }

    /// 录到全静音时的处理：**先自愈，再报告。**
    ///
    /// 最常见的原因不是权限，是回声消除。macOS 的语音处理单元会把输入
    /// 换成多声道格式，转换那一步一旦对不上就安静地输出全零 —— 权限、
    /// 引擎、tap 回调全都"正常"，只是每个采样都是 0。
    ///
    /// 所以先把回声消除摘掉再试。它是锦上添花，能听见才是底线。
    private func silentCaptureMessage() -> String {
        if recorder.echoCancellationActive {
            recorder.disableEchoCancellation()
            NSLog("MixDictate: 全静音且回声消除开着 —— 已自动关掉回声消除")
            return "回声消除把麦克风变哑了，已自动关掉，再说一次"
        }
        return microphoneHint
    }

    /// 麦克风一片死寂时该说什么。**「检查一下麦克风权限」是不够的** ——
    /// 用户会去看，发现开关明明是开的，然后就卡在那儿了。
    ///
    /// 最常见的原因恰恰是"开关开着但授权失效"：这个 App 是 ad-hoc 签名的，
    /// 每次重新编译哈希都变一个，而 TCC 是按签名记授权的，旧记录就对不上了。
    /// 系统设置里那个开关照常显示为开，麦克风也照常"工作"，只是样本全是零。
    private var microphoneHint: String {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            return "麦克风只送来静音 —— 授权多半在重装时失效了，点菜单里「重新申请麦克风权限…」"
        case .notDetermined:
            return "还没申请过麦克风权限，重启一下 App"
        default:
            return "麦克风权限没开，去系统设置 › 隐私与安全性 › 麦克风"
        }
    }

    /// 重装之后授权失效的自救入口。
    @objc private func requestMicrophoneAgain() {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "重新申请麦克风权限"
        alert.informativeText = """
            这个 App 用的是 ad-hoc 签名（没有开发者证书），每次重新编译签名的
            哈希都会换一个。而 macOS 是按签名记授权的，旧的那条就对不上了。

            麻烦的是系统设置里的开关**看着还是开的**，实际已经失效：麦克风照常
            工作，只是送来的样本全是零 —— 所以「我明明开了权限」是完全合理的
            困惑，不是你记错了。

            「重置并重启」会清掉这条记录并重开 App，下次录音时系统重新弹窗。
            """
        alert.addButton(withTitle: "重置并重启")
        alert.addButton(withTitle: "打开系统设置")
        alert.addButton(withTitle: "取消")

        switch alert.runModal() {
        case .alertFirstButtonReturn:
            resetMicrophoneAuthorization()
        case .alertSecondButtonReturn:
            SystemSettings.openMicrophone()
        default:
            break
        }
    }

    private func resetMicrophoneAuthorization() {
        let bundleID = Bundle.main.bundleIdentifier ?? "dev.mixdictate.app"
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/tccutil")
        // 只重置这一个 bundle id，不动系统里其他 App 的授权
        task.arguments = ["reset", "Microphone", bundleID]

        do {
            try task.run()
            task.waitUntilExit()
        } catch {
            NSLog("MixDictate: tccutil 跑不起来：%@", error.localizedDescription)
            SystemSettings.openMicrophone()
            return
        }

        // 必须重启：TCC 的判定结果在进程里是缓存住的，不重开这个进程，
        // 重置了也还是拿不到弹窗。
        relaunch()
    }

    private func relaunch() {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(
            at: Bundle.main.bundleURL, configuration: configuration
        ) { _, error in
            if let error {
                NSLog("MixDictate: 重启失败：%@", error.localizedDescription)
                return
            }
            Task { @MainActor in
                // 给新实例一点时间把菜单栏图标挂上，免得中间有一段
                // 两个都不在的空窗
                try? await Task.sleep(nanoseconds: 700_000_000)
                NSApp.terminate(nil)
            }
        }
    }

    private func reportMicrophoneDenied() {
        fail("麦克风权限被拒 —— 录不到任何声音")

        let alert = NSAlert()
        alert.messageText = "需要麦克风权限"
        alert.informativeText = "系统设置 › 隐私与安全性 › 麦克风，把 MixDictate 打开。"
        alert.addButton(withTitle: "打开设置")
        alert.addButton(withTitle: "稍后")
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn {
            SystemSettings.openMicrophone()
        }
    }

    // MARK: - 菜单栏

    private func refreshStatusItem() {
        guard let button = statusItem.button else { return }

        if let image = statusImage {
            button.image = image
            button.title = ""
        } else {
            // SF Symbol 拿不到时退回 emoji，至少菜单栏上还有个能点的东西
            button.image = nil
            button.title = fallbackTitle
        }
        button.toolTip = tooltip
    }

    /// 菜单栏图标。
    ///
    /// 待命和转写用模板图像（isTemplate = true）—— 模板图像会被系统按菜单栏的
    /// 明暗自动反色，浅色模式下是黑的，深色模式下是白的，跟旁边的系统图标一致。
    /// 录音和出错状态需要颜色来抓注意力，所以走 paletteColors，不能当模板。
    private var statusImage: NSImage? {
        let symbol: String
        let tint: NSColor?

        switch state {
        case .launching:
            symbol = "hourglass"
            tint = nil
        case .idle:
            symbol = "mic"
            tint = nil
        case .recording:
            symbol = "mic.fill"
            tint = .systemRed
        case .transcribing:
            symbol = "waveform"
            tint = nil
        case .failed:
            symbol = "exclamationmark.triangle.fill"
            tint = .systemOrange
        }

        guard let base = NSImage(systemSymbolName: symbol, accessibilityDescription: tooltip) else {
            return nil
        }

        var configuration = NSImage.SymbolConfiguration(pointSize: 15, weight: .regular)
        if let tint {
            configuration = configuration.applying(.init(paletteColors: [tint]))
        }

        let image = base.withSymbolConfiguration(configuration) ?? base
        image.isTemplate = (tint == nil)
        return image
    }

    private var fallbackTitle: String {
        switch state {
        case .launching:    return "⏸"
        case .idle:         return "🎙"
        case .recording:    return "🔴"
        case .transcribing: return "⏳"
        case .failed:       return "⚠️"
        }
    }

    private var tooltip: String {
        switch state {
        case .launching:    return "MixDictate · 正在启动转写服务…"
        case .idle:         return "MixDictate · 按住说话键开始"
        case .recording:    return "正在录音…"
        case .transcribing: return "正在转写…"
        case .failed:       return lastError ?? "出错了"
        }
    }

    private func buildMenu() {
        let menu = NSMenu()

        if let lastError, state == .failed {
            let item = NSMenuItem(title: lastError, action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
            menu.addItem(.separator())
        }

        let hint = NSMenuItem(
            title: "按住 \(HotKeyMonitor.displayName(for: config.pushToTalkKeyCode)) 说话，松开插入文字（Esc 取消）",
            action: nil,
            keyEquivalent: ""
        )
        hint.isEnabled = false
        menu.addItem(hint)
        menu.addItem(.separator())

        menu.addItem(NSMenuItem(title: "设置…", action: #selector(openSettings), keyEquivalent: ","))
        menu.addItem(NSMenuItem(title: "编辑热词表…", action: #selector(openHotwords), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "从听写记录里找热词…", action: #selector(openHotwordCandidates), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "检查服务状态", action: #selector(checkServer), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "重启转写服务", action: #selector(restartServer), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "查看服务日志…", action: #selector(openServerLog), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "查看转写记录…", action: #selector(openTranscriptLog), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "播放最近一次录音…", action: #selector(openLastRecording), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "校准人声门限…", action: #selector(calibrateThreshold), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "重新申请麦克风权限…", action: #selector(requestMicrophoneAgain), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "重新申请辅助功能权限…", action: #selector(requestAccessibilityAgain), keyEquivalent: ""))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "退出 MixDictate", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))

        menu.items.forEach { $0.target = $0.action == #selector(NSApplication.terminate(_:)) ? nil : self }
        statusItem.menu = menu
    }

    /// 热词表路径向服务端要，不能自己猜。
    /// .app 通过 Finder / open 启动时工作目录是 "/"，任何基于 cwd 的相对路径都会落空。
    @objc private func openHotwords() {
        Task { @MainActor in
            var request = URLRequest(url: config.healthURL)
            request.timeoutInterval = 3
            guard
                let (data, _) = try? await URLSession.shared.data(for: request),
                let health = try? JSONDecoder().decode(HealthResponse.self, from: data),
                let path = health.hotwordsPath
            else {
                let alert = NSAlert()
                alert.messageText = "拿不到热词表路径"
                alert.informativeText = "转写服务没在跑。用菜单里的「重启转写服务」再试一次。"
                alert.runModal()
                return
            }
            NSWorkspace.shared.open(URL(fileURLWithPath: path))
        }
    }

    @objc private func checkServer() {
        Task { @MainActor in
            var request = URLRequest(url: config.healthURL)
            request.timeoutInterval = 3
            let alert = NSAlert()
            do {
                let (data, _) = try await URLSession.shared.data(for: request)
                let health = try JSONDecoder().decode(HealthResponse.self, from: data)
                alert.messageText = "服务正常"
                alert.informativeText = """
                    模型：\(health.model)
                    热词：\(health.hotwords) 条
                    """
            } catch {
                alert.messageText = "连不上服务"
                alert.informativeText = "用菜单里的「重启转写服务」，还不行就看服务日志。"
            }
            alert.runModal()
        }
    }
}
