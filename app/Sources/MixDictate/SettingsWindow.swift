import AppKit
import SwiftUI

/// 设置界面。改完点保存，说话键立刻生效；换模型需要重启转写服务。
@MainActor
final class SettingsModel: ObservableObject {
    @Published var config: Config
    @Published var isCapturingKey = false
    @Published var statusMessage = ""

    /// 保存后回调，让 AppDelegate 决定要不要重挂热键 / 重启服务
    var onSave: ((Config, _ modelChanged: Bool) -> Void)?

    private var captureMonitor: Any?
    private let originalModel: String

    init(config: Config) {
        self.config = config
        self.originalModel = config.model
    }

    // MARK: - 录制说话键

    /// 直接监听 flagsChanged 而不是让用户从列表里选 —— "按一下你想用的键"
    /// 比"从一堆键码里挑"直观得多。
    func startCapturingKey() {
        guard !isCapturingKey else { return }
        isCapturingKey = true
        statusMessage = "按一下你想用的修饰键…"

        captureMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            guard let self else { return event }

            // 只接受已知可用的修饰键。普通字母键不能用 —— 按住说话期间
            // 那个字母会一直重复输入到当前输入框里。
            if HotKeyMonitor.selectableKeys.contains(where: { $0.code == event.keyCode }) {
                self.config.pushToTalkKeyCode = event.keyCode
                self.statusMessage = ""
                self.stopCapturingKey()
            } else {
                self.statusMessage = "这个键不能用，换一个修饰键（Option / Command / Control / Shift）"
            }
            return nil  // 吞掉事件，别传给别人
        }
    }

    func stopCapturingKey() {
        if let captureMonitor {
            NSEvent.removeMonitor(captureMonitor)
        }
        captureMonitor = nil
        isCapturingKey = false
    }

    // MARK: - 保存

    func save() {
        stopCapturingKey()
        do {
            try config.save()
            onSave?(config, config.model != originalModel)
            statusMessage = "已保存"
        } catch {
            statusMessage = "保存失败：\(error.localizedDescription)"
        }
    }
}

struct SettingsView: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            GroupBox("说话键") {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("按住这个键说话：")
                        Spacer()
                        Button(buttonLabel) {
                            if model.isCapturingKey {
                                model.stopCapturingKey()
                            } else {
                                model.startCapturingKey()
                            }
                        }
                        .frame(minWidth: 140)
                    }
                    Text("点上面的按钮，然后按一下你想用的修饰键。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(6)
            }

            GroupBox("文字处理") {
                VStack(alignment: .leading, spacing: 8) {
                    Toggle("去掉「嗯」「呃」这类口语词", isOn: $model.config.stripFillers)
                    Toggle("中文标点转全角（，。？！）", isOn: $model.config.fullwidthPunctuation)
                    Text("关掉全角后标点保持半角，写代码时更顺手。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(6)
            }

            GroupBox("识别模型") {
                VStack(alignment: .leading, spacing: 8) {
                    Picker("模型", selection: $model.config.model) {
                        ForEach(ASRModel.allCases, id: \.rawValue) { option in
                            Text(option.label).tag(option.rawValue)
                        }
                    }
                    .labelsHidden()
                    Text("换模型后会自动重启转写服务，第一次要下载模型。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(6)
            }

            HStack {
                Text(model.statusMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("保存") { model.save() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 420)
    }

    private var buttonLabel: String {
        model.isCapturingKey
            ? "按一下…（点这里取消）"
            : HotKeyMonitor.displayName(for: model.config.pushToTalkKeyCode)
    }
}

@MainActor
final class SettingsWindowController {
    private var window: NSWindow?
    private var model: SettingsModel?

    func show(config: Config, onSave: @escaping (Config, Bool) -> Void) {
        // 已经开着就只是拿到前台，别开第二个窗口
        if let window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let model = SettingsModel(config: config)
        model.onSave = onSave

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 480),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "MixDictate 设置"
        window.contentViewController = NSHostingController(rootView: SettingsView(model: model))
        window.center()
        window.isReleasedWhenClosed = false

        self.window = window
        self.model = model

        window.makeKeyAndOrderFront(nil)
        // 菜单栏 App 是 .accessory，不主动激活的话窗口不会拿到焦点，
        // 录键盘就录不到
        NSApp.activate(ignoringOtherApps: true)
    }

    func close() {
        model?.stopCapturingKey()
        window?.close()
    }
}
