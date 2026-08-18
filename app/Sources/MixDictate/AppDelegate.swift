import AppKit
import AVFoundation

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var monitor: HotKeyMonitor?
    private let recorder = AudioRecorder()
    private var config = Config.load()
    private var lastError: String?

    private enum State {
        case idle, recording, transcribing, failed
    }

    private var state: State = .idle {
        didSet { refreshStatusItem() }
    }

    // MARK: - 生命周期

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        buildMenu()
        refreshStatusItem()

        requestMicrophoneAccess()
        TextInjector.ensureAccessibilityPermission(prompt: true)

        monitor = HotKeyMonitor(
            keyCode: config.pushToTalkKeyCode,
            onPress: { [weak self] in self?.beginRecording() },
            onRelease: { [weak self] in self?.endRecording() }
        )
        monitor?.start()
    }

    func applicationWillTerminate(_ notification: Notification) {
        monitor?.stop()
    }

    // MARK: - 录音 → 转写 → 插入

    private func beginRecording() {
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
        let title: String
        switch state {
        case .idle:         title = "🎙"
        case .recording:    title = "🔴"
        case .transcribing: title = "⏳"
        case .failed:       title = "⚠️"
        }
        statusItem.button?.title = title
        statusItem.button?.toolTip = tooltip
    }

    private var tooltip: String {
        switch state {
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

    @objc private func openHotwords() {
        let path = ProcessInfo.processInfo.environment["MIXDICTATE_HOTWORDS"]
            ?? FileManager.default.currentDirectoryPath + "/config/hotwords.txt"
        NSWorkspace.shared.open(URL(fileURLWithPath: path))
    }

    @objc private func checkServer() {
        Task { @MainActor in
            var request = URLRequest(url: config.healthURL)
            request.timeoutInterval = 3
            let alert = NSAlert()
            do {
                let (data, _) = try await URLSession.shared.data(for: request)
                alert.messageText = "服务正常"
                alert.informativeText = String(data: data, encoding: .utf8) ?? ""
            } catch {
                alert.messageText = "连不上服务"
                alert.informativeText = "先在项目目录里运行 make server"
            }
            alert.runModal()
        }
    }
}
