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

    /// 哪些组是展开的。默认全收起 —— 这些设置调好一次就很少再动，
    /// 却每次打开设置都要占掉整屏高度。
    @State private var expanded: Set<String> = []

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

    // 说明文字全部收进悬停提示。它们本来占掉了大半个窗口的高度 ——
    // 而一个非得开这么大才装得下的设置面板，本身就是设计有问题。
    // 收进 .help() 之后信息一个字没少，只是从"一直摊开"变成"要看才看"。
    @ViewBuilder
    private var settingsGroups: some View {
        VStack(alignment: .leading, spacing: 12) {
            GroupBox {
                HStack {
                    Text("按住说话")
                    Spacer()
                    Button(buttonLabel) {
                        if model.isCapturingKey {
                            model.stopCapturingKey()
                        } else {
                            model.startCapturingKey()
                        }
                    }
                    .frame(minWidth: 140)
                    .help("点一下，然后按你想用的修饰键。听写中按 Esc 取消。")
                }
                .padding(6)
            }

            permissionsBox

            section("录音", "人声门限、停顿压缩、回声消除") {
                Toggle("回声消除", isOn: $model.config.echoCancellation)
                    .help("""
                        默认关。打开后电脑自己放的声音不会被录进去，但 macOS 上有两个躲不开的代价：
                        ① 整台电脑的音量会被压低 —— 语音处理单元是给通话用的，一开启系统就压低其他所有声音，这个行为关不掉。
                        ② 它会把输入换成多声道，转换对不上时采集会整个变成静音。
                        挡外放用人声门限就够了，代价小得多。
                        """)

                slider("人声门限", value: $model.config.voiceThreshold,
                       range: 0...0.3, format: "%.2f", width: 36,
                       help: """
                        默认 0（关闭）。打开后，低于门限的声音直接丢掉，不送去转写。
                        只在你必须外放着听写时才需要它 —— 代价是它只能按响度判断，而「整句都说得轻」和「这是外放漏进来的」在响度上是同一件事，一路轻声说的话可能整句都收不到。
                        该设多少不用猜：菜单里有「校准人声门限…」，量两次给建议值。
                        想彻底隔绝外放，戴耳机才是唯一可靠的办法。
                        """)

                slider("停顿压到", value: $model.config.maxPauseSeconds,
                       range: 0...1.5, format: "%.2fs", width: 48,
                       help: """
                        送给模型前把长停顿压短。模型判断句子说完没有主要就是看停顿多长，而「在想下一句」和「这句说完了」在音频里是同一件事，分不开。
                        与其猜，不如把线索削掉：调小就更不会在你停顿时乱加句号，调大更尊重你的停顿。0 = 不压。
                        顺带音频变短，转写也更快。
                        """)
            }

            section("文字处理", "口语词、数字符号、标点") {
                Toggle("只要模型原文，不做任何加工", isOn: $model.config.rawOutput)
                    .help("打开后下面的开关全部失效。用来判断奇怪的输出是模型听错了还是后处理改坏了 —— 这两件事的解法完全不同。")

                Divider()

                Toggle("录音时显示实时浮层", isOn: $model.config.showLiveOverlay)
                slider("浮层不透明度", value: $model.config.overlayOpacity,
                       range: 0.2...1.0, format: "%.2f", width: 40,
                       help: "浮层固定在屏幕上一块地方，底下正好是你在看的东西。调低更不挡视线，调高更清楚。用鼠标拖它就能换位置，拖到哪儿记到哪儿。")
                Toggle("去掉「嗯」「呃」这类口语词（默认关，会删字）", isOn: $model.config.stripFillers)
                    .help("默认关闭：这是唯一还会删字的加工。「嗯，可以」里那个「嗯」可能是回答而不是语气词，从文字上分不出来。多余的字你一眼能看见并删掉，被删掉的字你根本不知道它曾经存在过。")
                Toggle("合并卡壳时的重复", isOn: $model.config.collapseRepeats)
                    .help("默认关。「超级超级好」是刻意强调不是卡壳，删错的代价比留着重复大得多。")
                Toggle("中文标点转全角", isOn: $model.config.fullwidthPunctuation)
                    .help("关掉后标点保持半角，写代码时更顺手。")
                Toggle("口语数字转阿拉伯数字", isOn: $model.config.spokenNumbers)
                    .help("三点一四 → 3.14")
                Toggle("口语符号转符号", isOn: $model.config.spokenSymbols)
                    .help("艾特 gmail 点 com → @gmail.com")
                Toggle("停顿处误加的句号降级成逗号", isOn: $model.config.mergePausePeriods)
                    .help("句号后面跟着「然后」「但是」这类接续词，说明这句还没说完。只改标点，不删字。")
                Toggle("长句里给接续词补逗号", isOn: $model.config.splitClauses)
                    .help("说得顺的时候分句处根本不停，没有停顿模型就不给逗号，一句话能拖很长。接续词就是分句的位置，这一点不用听也知道。只加逗号，不动字。")
            }

            section("输入方式", "怎么把文字送进输入框") {
                Toggle("边说边写进输入框（准确率不如关着）", isOn: $model.config.liveInsertion)
                    .help("""
                        默认关闭，**追求准确就一直关着**。

                        关着的时候：松手后一次性插入，中间不改动任何东西，最稳。
                        开着的时候：文字边说边出现，但模型会不断回头修正前面的词，所以要靠退格重写来跟上。而"输入框里现在是什么"我们只能靠推算，一旦跟真实情况对不上（事件被丢、你自己动了光标、App 自动补全），就可能改错地方。

                        它现在会在退格前先核对，对不上就停手、把完整文字放进剪贴板 —— 但那意味着这一次的实时写入没做完。
                        """)
                Text("追求准确率就关掉它：关着是松手后一次性插入，中间不改动任何东西。")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Picker("送进去的方式", selection: $model.config.insertionMethod) {
                    ForEach(InsertionMethod.allCases, id: \.rawValue) { option in
                        Text(option.label).tag(option.rawValue)
                    }
                }
                .help("先试粘贴。个别 App 会拦截粘贴，那种情况改成逐字输入。")
            }

            section("学习", "从你的修改里学热词（默认关）") {
                Toggle("学习我对听写结果的修改", isOn: $model.config.learnCorrections)
                    .help("""
                        听写完几秒后回头看一眼：我们写进去的那段，你改了什么。
                        同一个改动出现 3 次就写进热词表，以后自动改对。

                        这是唯一会碰输入框的功能，所以口子开得很小：只按范围读我们自己写的那一段，控件不支持按范围读就放弃这次学习，绝不退回去读全文。学到的只存本机，不联网。

                        默认关闭。不想让它碰输入框就一直关着 —— 菜单里的「从听写记录里找热词…」不需要这个开关，它只读转写记录。
                        """)
            }

            section("识别模型", "换模型会重启转写服务") {
                Picker("模型", selection: $model.config.model) {
                    ForEach(ASRModel.allCases, id: \.rawValue) { option in
                        Text(option.label).tag(option.rawValue)
                    }
                }
                .help("换模型后会自动重启转写服务，第一次要下载模型。")
            }
        }
    }

    /// 权限都正常时压成一行。它平时是背景信息，出问题时才需要占地方 ——
    /// 让"一切正常"和"出事了"占一样大的篇幅，等于两边都看不见。
    @ViewBuilder
    private var permissionsBox: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                if model.hasMicrophone && model.hasAccessibility {
                    HStack(spacing: 6) {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                        Text("麦克风、辅助功能都已授权")
                            .font(.caption)
                        Spacer()
                    }
                } else {
                    permissionRow(
                        granted: model.hasMicrophone,
                        name: "麦克风",
                        problem: "未授权 —— 录不到声音",
                        open: SystemSettings.openMicrophone
                    )
                    permissionRow(
                        granted: model.hasAccessibility,
                        name: "辅助功能",
                        problem: "未授权 —— 说话键收不到按键，文字也插不进输入框",
                        open: SystemSettings.openAccessibility
                    )
                }
            }
            .padding(6)
        }
    }

    @ViewBuilder
    private func permissionRow(
        granted: Bool, name: String, problem: String, open: @escaping () -> Void
    ) -> some View {
        HStack {
            Image(systemName: granted
                  ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(granted ? .green : .orange)
            VStack(alignment: .leading, spacing: 2) {
                Text(name)
                if !granted {
                    Text(problem)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            if !granted {
                Button("去授权", action: open)
            }
        }
    }

    /// 可折叠的一组。默认收起 —— 这些设置调好一次就很少再动，
    /// 却每次打开设置都要占掉整屏。
    private func section<Content: View>(
        _ title: String,
        _ subtitle: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        // 先把 content 求值成一个具体的 View 再往下传。DisclosureGroup 会把
        // 传给它的闭包存起来（逃逸），而 @ViewBuilder 参数默认是非逃逸的 ——
        // 直接在里面调 content() 就是"逃逸闭包捕获非逃逸参数"。
        let inner = content()
        return GroupBox {
            DisclosureGroup(
                isExpanded: Binding(
                    get: { expanded.contains(title) },
                    set: { isOpen in
                        if isOpen { expanded.insert(title) } else { expanded.remove(title) }
                    }
                )
            ) {
                VStack(alignment: .leading, spacing: 8) {
                    inner
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 8)
            } label: {
                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(6)
        }
    }

    @ViewBuilder
    private func slider(
        _ title: String,
        value: Binding<Double>,
        range: ClosedRange<Double>,
        format: String,
        width: CGFloat,
        help: String
    ) -> some View {
        HStack {
            Text(title)
            Slider(value: value, in: range)
            Text(String(format: format, value.wrappedValue))
                .font(.system(.caption, design: .monospaced))
                .frame(width: width, alignment: .trailing)
        }
        .help(help)
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
        // 全部收起时内容很矮，默认窗口就按那个来。真要展开几组，
        // 窗口可以拉大，装不下的部分也能滚。
        let visibleHeight = NSScreen.main?.visibleFrame.height ?? 800
        let height = min(440, max(320, visibleHeight - 200))

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
