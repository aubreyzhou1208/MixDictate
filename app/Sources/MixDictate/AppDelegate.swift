import AppKit
import AVFoundation

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var monitor: HotKeyMonitor?
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
    private var pendingEnd = 0
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
            try recorder.start()
            silentTicks = 0
            committedText = ""
            pendingText = ""
            pendingEnd = 0
            liveInserter.reset()
            state = .recording
            if config.showLiveOverlay {
                // 实时写入时只给一个小指示器：文字已经在光标处了，浮层
                // 再显示一遍是噪音；但完全不显示又会让人不确定它在不在工作。
                overlay.show(
                    style: config.liveInsertion ? .compact : .fullText,
                    status: config.liveInsertion ? "正在听写" : "听着呢…"
                )
            }
            // 实时写入也要靠中间结果，即使浮层关着
            if config.showLiveOverlay || config.liveInsertion {
                startPartialUpdates()
            }
        } catch {
            fail("麦克风打不开：\(error.localizedDescription)")
        }
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
            // 请求飞在路上时用户可能已经松手了，这时别再盖掉最终结果
            guard state == .recording else { return }
            // 空结果别覆盖掉「没有听到声音」那条提示
            guard !text.isEmpty else { return }

            pendingText = text
            pendingEnd = snapshot.endOffset

            if let boundary = snapshot.boundary {
                // 这一段就此定稿 —— 之后不会再转写它。这是长录音不再越来越慢
                // 的关键：开销只跟"最后一段"有关，跟总时长无关。
                //
                // 按长度硬切的段落一定断在句子中间，模型却会给它补一个句号。
                // 直接拼下去会出现「这个方案。确实不错」这种断句。
                committedText += boundary == .lengthCap
                    ? Self.strippingSentenceEnd(text)
                    : text
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

        guard let tailWav = recorder.stop(minimumDuration: config.minimumDurationSeconds) else {
            // 以前这里是静默返回的，结果就是「按了没反应」—— 用户完全无从
            // 判断是按太短了还是麦克风根本没工作。这两件事必须说清楚。
            let reason = recorder.heardSound
                ? "太短了，没录到内容"
                : "没有听到声音，检查一下麦克风权限"
            overlay.setStatus(reason)
            overlay.update(reason, isFinal: true)
            overlay.hide(after: 1.6)
            state = .idle
            return
        }

        // 尾巴是空的：说话正好停在段落边界上，全部内容都已经定稿
        if tailWav.isEmpty {
            deliver(committedText)
            return
        }

        // 尾巴比最后一次中间结果几乎没长（0.4 秒以内），那次的文字就是
        // 最终结果。再跑一次推理纯属重复劳动，而松手之后的等待恰恰是
        // 整个流程里最难受的一段。
        if !pendingText.isEmpty,
           recorder.capturedBytes - pendingEnd < Self.reusePartialThresholdBytes {
            NSLog("MixDictate: 尾部音频未再增长，直接用最后一次中间结果")
            deliver(committedText + pendingText)
            return
        }

        state = .transcribing
        overlay.setStatus("整理中…")
        overlay.update("整理中…", isFinal: false)
        let client = TranscriptionClient(config: config)

        Task { @MainActor in
            do {
                // 只转最后这一段。前面的段落早就转过并定稿了 ——
                // 这就是长录音松手后不再等很久的原因。
                let tail = try await client.transcribe(wav: tailWav)
                let text = committedText + tail

                guard !text.isEmpty else {
                    let reason = recorder.heardSound
                        ? "没识别出内容"
                        : "没有听到声音，检查一下麦克风权限"
                    overlay.setStatus(reason)
                    overlay.update(reason, isFinal: true)
                    overlay.hide(after: 1.6)
                    state = .idle
                    return
                }
                deliver(text)
            } catch {
                // 错误必须显示在浮层上。只写进菜单栏图标是不够的 ——
                // 菜单栏图标多了会被刘海挤掉，用户根本看不见，
                // 于是转写失败在他眼里就成了「什么都没发生」。
                overlay.setStatus("出错了")
                overlay.update("出错了：\(error.localizedDescription)", isFinal: true)
                overlay.hide(after: 5)
                fail(error.localizedDescription)
            }
        }
    }

    /// 去掉句末标点。段落是按长度硬切出来的时候用 ——
    /// 那种切口在句子中间，模型补的句号是错的。
    private static func strippingSentenceEnd(_ text: String) -> String {
        var result = text
        while let last = result.last, "。！？，、.!?,".contains(last) {
            result.removeLast()
        }
        return result
    }

    /// 0.4 秒的 16kHz 单声道 16 位音频。低于这个增量就认为内容没变。
    private static let reusePartialThresholdBytes = 12_800

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
            return
        }

        // 先把最终结果显示出来，用户能看到它跟中间结果差在哪
        overlay.update(text, isFinal: true)

        switch TextInjector.insert(text, method: config.resolvedInsertionMethod) {
        case .inserted(let method):
            NSLog("MixDictate: 已通过 %@ 插入", method.rawValue)
            overlay.hide(after: 1.2)
        case .insertedViaAccessibility:
            // 安全输入模式挡住了合成按键，但辅助功能接口写进去了
            NSLog("MixDictate: 安全输入模式，已改走辅助功能接口")
            overlay.hide(after: 1.2)
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
            title: "按住 \(HotKeyMonitor.displayName(for: config.pushToTalkKeyCode)) 说话，松开插入文字",
            action: nil,
            keyEquivalent: ""
        )
        hint.isEnabled = false
        menu.addItem(hint)
        menu.addItem(.separator())

        menu.addItem(NSMenuItem(title: "设置…", action: #selector(openSettings), keyEquivalent: ","))
        menu.addItem(NSMenuItem(title: "编辑热词表…", action: #selector(openHotwords), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "检查服务状态", action: #selector(checkServer), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "重启转写服务", action: #selector(restartServer), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "查看服务日志…", action: #selector(openServerLog), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "查看转写记录…", action: #selector(openTranscriptLog), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "播放最近一次录音…", action: #selector(openLastRecording), keyEquivalent: ""))
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
