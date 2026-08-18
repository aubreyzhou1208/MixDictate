import AppKit
import AVFoundation

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var monitor: HotKeyMonitor?
    private let recorder = AudioRecorder()
    private var config = Config.load()
    private var server: ServerProcess!
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

        monitor = HotKeyMonitor(
            keyCode: config.pushToTalkKeyCode,
            onPress: { [weak self] in self?.beginRecording() },
            onRelease: { [weak self] in self?.endRecording() }
        )
        monitor?.start()
    }

    func applicationWillTerminate(_ notification: Notification) {
        monitor?.stop()
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

    @objc private func restartServer() {
        server.stop()
        Task { @MainActor in await startServer() }
    }

    @objc private func openServerLog() {
        NSWorkspace.shared.open(ServerProcess.logURL)
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
        } catch {
            fail("麦克风打不开：\(error.localizedDescription)")
        }
    }

    private func endRecording() {
        guard state == .recording else { return }

        guard let wav = recorder.stop(minimumDuration: config.minimumDurationSeconds) else {
            // 按得太短或没录到声音，静默回到待命，不打扰用户
            state = .idle
            return
        }

        state = .transcribing
        let client = TranscriptionClient(config: config)

        Task { @MainActor in
            do {
                let text = try await client.transcribe(wav: wav)
                if text.isEmpty {
                    state = .idle
                } else {
                    TextInjector.insert(text)
                    state = .idle
                }
            } catch {
                fail(error.localizedDescription)
            }
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
            title: "按住 \(keyName(config.pushToTalkKeyCode)) 说话，松开插入文字",
            action: nil,
            keyEquivalent: ""
        )
        hint.isEnabled = false
        menu.addItem(hint)
        menu.addItem(.separator())

        menu.addItem(NSMenuItem(title: "编辑热词表…", action: #selector(openHotwords), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "检查服务状态", action: #selector(checkServer), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "重启转写服务", action: #selector(restartServer), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "查看服务日志…", action: #selector(openServerLog), keyEquivalent: ""))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "退出 MixDictate", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))

        menu.items.forEach { $0.target = $0.action == #selector(NSApplication.terminate(_:)) ? nil : self }
        statusItem.menu = menu
    }

    private func keyName(_ code: UInt16) -> String {
        switch code {
        case 61: return "右 Option"
        case 58: return "左 Option"
        case 54: return "右 Command"
        case 62: return "右 Control"
        default: return "键 \(code)"
        }
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
