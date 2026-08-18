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
    private var partialTimer: Timer?
    /// 同一时刻只允许一个中间请求在飞。模型是串行的，堆积请求
    /// 只会让松手后的最终结果排在后面等更久。
    private var partialInFlight = false
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
        TextInjector.ensureAccessibilityPermission(prompt: true)

        server = ServerProcess(config: config)
        Task { @MainActor in await startServer() }

        installHotKeyMonitor()
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
        server?.stop()
    }

    // MARK: - 转写服务

    private func startServer() async {
        state = .launching
        switch await server.start() {
        case .ready:
            state = .idle
            lastError = nil
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
            state = .recording
            if config.showLiveOverlay {
                overlay.show(placeholder: "听着呢…")
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
        partialTimer?.invalidate()
        partialTimer = Timer.scheduledTimer(
            withTimeInterval: config.partialIntervalSeconds,
            repeats: true
        ) { [weak self] _ in
            Task { @MainActor in self?.requestPartial() }
        }
    }

    private func stopPartialUpdates() {
        partialTimer?.invalidate()
        partialTimer = nil
    }

    private func requestPartial() {
        guard state == .recording, !partialInFlight else { return }
        guard let wav = recorder.snapshotWAV() else { return }

        partialInFlight = true
        let client = TranscriptionClient(config: config)

        Task { @MainActor in
            defer { partialInFlight = false }
            guard let text = try? await client.transcribe(wav: wav, partial: true) else { return }
            // 请求飞在路上时用户可能已经松手了，这时别再盖掉最终结果
            guard state == .recording else { return }
            overlay.update(text, isFinal: false)
        }
    }

    private func endRecording() {
        guard state == .recording else { return }
        stopPartialUpdates()

        guard let wav = recorder.stop(minimumDuration: config.minimumDurationSeconds) else {
            // 按得太短或没录到声音，静默回到待命，不打扰用户
            state = .idle
            overlay.hide()
            return
        }

        state = .transcribing
        overlay.update("整理中…", isFinal: false)
        let client = TranscriptionClient(config: config)

        Task { @MainActor in
            do {
                let text = try await client.transcribe(wav: wav)
                guard !text.isEmpty else {
                    state = .idle
                    overlay.hide()
                    return
                }

                // 先把最终结果显示出来，用户能看到它跟中间结果差在哪
                overlay.update(text, isFinal: true)

                if TextInjector.insert(text) {
                    overlay.hide(after: 1.2)
                } else {
                    // 没有辅助功能权限时系统会静默丢掉合成的按键 ——
                    // 必须明确告诉用户，否则表现就是"按了没反应"
                    overlay.hide()
                    reportAccessibilityMissing()
                }
                state = .idle
            } catch {
                overlay.hide()
                fail(error.localizedDescription)
            }
        }
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
            TextInjector.openAccessibilitySettings()
        }
    }

    private func fail(_ message: String) {
        lastError = message
        state = .failed
        buildMenu()
        NSLog("MixDictate: %@", message)
    }

    // MARK: - 权限

    private func requestMicrophoneAccess() {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            break
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { _ in }
        default:
            fail("麦克风权限被拒绝，去系统设置 › 隐私与安全性 › 麦克风 里打开")
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
