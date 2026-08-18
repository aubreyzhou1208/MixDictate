import AppKit
import AVFoundation
import SwiftUI

/// 设置界面。改完点保存，说话键立刻生效；换模型需要重启转写服务。
@MainActor
final class SettingsModel: ObservableObject {
    @Published var config: Config
    @Published var isCapturingKey = false
    @Published var statusMessage = ""
    /// 打开设置时复查一次。权限可能在 App 运行期间被撤销，
    /// 也可能因为重新编译（签名变了）而失效。
    @Published var hasAccessibility = TextInjector.hasAccessibilityPermission
    @Published var hasMicrophone = SettingsModel.microphoneGranted

    /// 保存后回调，让 AppDelegate 决定要不要重挂热键 / 重启服务
    var onSave: ((Config, _ modelChanged: Bool) -> Void)?

    private var captureMonitor: Any?
    private let originalModel: String

    init(config: Config) {
        self.config = config
        self.originalModel = config.model
        self.hasAccessibility = TextInjector.hasAccessibilityPermission
        self.hasMicrophone = SettingsModel.microphoneGranted
    }

    static var microphoneGranted: Bool {
        AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
    }

    func refreshPermissions() {
        hasAccessibility = TextInjector.hasAccessibilityPermission
        hasMicrophone = SettingsModel.microphoneGranted
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
        // 设置项只会越加越多，窗口高度却是有限的。不放进 ScrollView 的话，
        // 超出的部分既看不见也够不着 —— 而"够不着"比"难看"严重得多。
        //
        // 保存按钮留在滚动区外面固定住：让人先滚到底才能保存，
        // 是同一个毛病换了个位置。
        VStack(spacing: 0) {
            ScrollView {
                settingsGroups
                    .padding(20)
            }

            Divider()

            HStack {
                Text(model.statusMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("保存") { model.save() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
        }
        // 只约束宽度。给了 minHeight 的话，NSHostingController 会把它变成
        // 窗口的最小高度约束，窗口就再也拉不小了 —— 而拉不小就永远轮不到
        // 滚动条出场，因为内容永远装得下。
        .frame(minWidth: 440)
        // 用户可能开着设置窗口跑去系统设置里授权，回来时要能看到状态更新
        .onReceive(
            NotificationCenter.default.publisher(
                for: NSApplication.didBecomeActiveNotification
            )
        ) { _ in
            model.refreshPermissions()
        }
    }

    @ViewBuilder
    private var settingsGroups: some View {
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

            GroupBox("权限") {
              VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Image(systemName: model.hasMicrophone
                          ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                        .foregroundStyle(model.hasMicrophone ? .green : .orange)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("麦克风")
                        Text(model.hasMicrophone
                             ? "已授权"
                             : "未授权 —— 录不到声音，浮层会一直空着")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    if !model.hasMicrophone {
                        Button("去授权") { SystemSettings.openMicrophone() }
                    }
                }

                HStack {
                    Image(systemName: model.hasAccessibility
                          ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                        .foregroundStyle(model.hasAccessibility ? .green : .orange)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("辅助功能")
                        Text(model.hasAccessibility
                             ? "已授权，可以自动输入文字"
                             : "未授权 —— 转写正常但文字插不进输入框")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    if !model.hasAccessibility {
                        Button("去授权") { SystemSettings.openAccessibility() }
                    }
                }
              }
                .padding(6)
            }

            GroupBox("录音") {
                VStack(alignment: .leading, spacing: 8) {
                    Toggle("回声消除（默认关，代价见下）", isOn: $model.config.echoCancellation)
                    Text("打开后电脑自己放的声音不会被录进去，但在 macOS 上有两个躲不开的代价：\n"
                         + "① 整台电脑的音量会被压低 —— 语音处理单元是给通话用的，\n"
                         + "   一开启系统就压低其他所有声音，这个行为 macOS 上关不掉。\n"
                         + "② 它会把输入换成多声道，转换对不上时采集会整个变成静音。\n"
                         + "挡外放用下面的人声门限就够了，代价小得多。")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Divider()

                    HStack {
                        Text("人声门限")
                        Slider(value: $model.config.voiceThreshold, in: 0...0.3)
                        Text(String(format: "%.2f", model.config.voiceThreshold))
                            .font(.system(.caption, design: .monospaced))
                            .frame(width: 36, alignment: .trailing)
                    }
                    Text("低于门限的声音直接丢掉，不送去转写。外放的视频漏进麦克风时\n"
                         + "通常比你说话弱一个数量级，这一刀就能挡住大部分。\n"
                         + "调大更能挡外放，调小小声说话也收得到，0 = 关掉。\n"
                         + "该设多少不用猜 —— 菜单里有「校准人声门限…」，量两次给建议值。\n"
                         + "想彻底隔绝请戴耳机 —— 声音根本不进麦克风才是真的隔绝。")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Divider()

                    HStack {
                        Text("停顿压到")
                        Slider(value: $model.config.maxPauseSeconds, in: 0...1.5)
                        Text(String(format: "%.2fs", model.config.maxPauseSeconds))
                            .font(.system(.caption, design: .monospaced))
                            .frame(width: 48, alignment: .trailing)
                    }
                    Text("送给模型前把长停顿压短。模型判断句子说完没有，主要就是看停顿多长，\n"
                         + "而「在想下一句」和「这句说完了」在音频里是同一件事，分不开。\n"
                         + "与其猜，不如把线索削掉：调小就更不会在你停顿时乱加句号，\n"
                         + "调大更尊重你的停顿。0 = 不压。顺带音频变短，转写也更快。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(6)
            }

            GroupBox("文字处理") {
                VStack(alignment: .leading, spacing: 8) {
                    Toggle("只要模型原文，不做任何加工", isOn: $model.config.rawOutput)
                    Text("打开后下面的开关全部失效。用来判断奇怪的输出是模型听错了\n"
                         + "还是后处理改坏了 —— 这两件事的解法完全不同。")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Divider()

                    Toggle("录音时在屏幕上显示实时结果", isOn: $model.config.showLiveOverlay)
                    Toggle("去掉「嗯」「呃」这类口语词", isOn: $model.config.stripFillers)
                    Toggle("合并卡壳时的重复（默认关，容易误删）", isOn: $model.config.collapseRepeats)
                    Toggle("中文标点转全角（，。？！）", isOn: $model.config.fullwidthPunctuation)
                    Toggle("口语数字转阿拉伯数字（三点一四 → 3.14）", isOn: $model.config.spokenNumbers)
                    Toggle("口语符号转符号（艾特 gmail 点 com → @gmail.com）", isOn: $model.config.spokenSymbols)
                    Toggle("停顿处误加的句号降级成逗号", isOn: $model.config.mergePausePeriods)
                    Text("关掉全角后标点保持半角，写代码时更顺手。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(6)
            }

            GroupBox("输入方式") {
                VStack(alignment: .leading, spacing: 8) {
                    Toggle("边说边写进输入框", isOn: $model.config.liveInsertion)
                    Text("开启后文字直接出现在光标处，不用等松手，也不再多一次粘贴。\n"
                         + "代价：模型会边说边修正前面的词，所以你会看到文字被退删重写；\n"
                         + "而且听写过程中别自己动光标或改字，否则退删会误伤你的内容。")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Divider()

                    Picker("输入方式", selection: $model.config.insertionMethod) {
                        ForEach(InsertionMethod.allCases, id: \.rawValue) { option in
                            Text(option.label).tag(option.rawValue)
                        }
                    }
                    .labelsHidden()
                    Text("先试粘贴。个别 App 会拦截粘贴，那种情况改成逐字输入。")
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
        }
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

        // 可缩放 + 有最小尺寸。固定尺寸的窗口一旦装不下内容就彻底没救 ——
        // 既不能拉大也不能滚动，那部分设置等于不存在。
        //
        // 默认高度按屏幕来定：外接大屏上可以一次看完，
        // 笔记本屏幕上也不会高过可用区域。
        let visibleHeight = NSScreen.main?.visibleFrame.height ?? 800
        let height = min(620, max(420, visibleHeight - 160))

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 460, height: height),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.minSize = NSSize(width: 440, height: 320)
        window.title = "MixDictate 设置"

        // 关键的一行。NSHostingController 默认会按 SwiftUI 内容的理想尺寸
        // 给窗口装上约束（sizingOptions 默认含 .preferredContentSize），
        // 于是窗口被撑成内容那么大、而且**小不下去**：
        //   · 内容比屏幕高 → 下半截够不着
        //   · 窗口不能拉小 → ScrollView 永远有富余空间 → 滚动条永远不出现
        // 加了 ScrollView 却还是滚不动、拉不小，就是卡在这儿。
        // 清空 sizingOptions 之后，尺寸完全由窗口自己说了算。
        let hosting = NSHostingController(rootView: SettingsView(model: model))
        hosting.sizingOptions = []
        window.contentViewController = hosting

        // contentViewController 赋值时窗口会被重设成控制器的尺寸，
        // 所以要在这之后再把想要的尺寸设回去
        window.setContentSize(NSSize(width: 460, height: height))
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
