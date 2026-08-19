import AppKit
import SwiftUI

/// 从听写记录里挑热词候选，让用户一条条确认。
///
/// **没有任何自动入表的路径。** 词表是偏置解码器用的，一个听错的词进了表，
/// 会让模型把这个错误听得更稳定 —— 那比不加还糟。所以这里只提供候选，
/// 勾选和「加入」是必须由人做的动作。
///
/// 候选只来自本机那个转写日志。最初想的是读当前输入框的内容来学词，
/// 那样候选更准，但它要去读用户正在写的东西 —— 邮件、密码框旁边的字段、
/// 别人发来的消息。改成只看转写日志之后，读到的全是用户自己对着这个 App
/// 说过的话。
struct HotwordCandidate: Identifiable, Decodable {
    var term: String
    var count: Int

    var id: String { term }
}

@MainActor
final class HotwordCandidatesModel: ObservableObject {
    @Published var candidates: [HotwordCandidate] = []
    @Published var selected: Set<String> = []
    @Published var status = "正在从听写记录里找…"
    @Published var busy = true

    private let config: Config

    init(config: Config) {
        self.config = config
    }

    private var candidatesURL: URL {
        base().appendingPathComponent("hotwords/candidates")
    }

    private var addURL: URL {
        base().appendingPathComponent("hotwords/add")
    }

    private func base() -> URL {
        URL(string: config.serverURL) ?? URL(string: "http://127.0.0.1:8765")!
    }

    func load() async {
        busy = true
        defer { busy = false }

        struct Response: Decodable {
            var candidates: [HotwordCandidate]
            var note: String?
        }

        do {
            let (data, _) = try await URLSession.shared.data(from: candidatesURL)
            let decoded = try JSONDecoder().decode(Response.self, from: data)
            candidates = decoded.candidates
            selected = []

            if let note = decoded.note {
                status = note
            } else if candidates.isEmpty {
                status = "没找到候选 —— 多用一阵子再来看，"
                    + "反复出现两次以上的英文词才会被挑出来。"
            } else {
                status = "勾上你确实想让它认准的词。没把握的就别勾 ——"
                    + "听错的词进了表会让它错得更稳。"
            }
        } catch {
            status = "连不上转写服务：\(error.localizedDescription)"
            candidates = []
        }
    }

    func add() async {
        let terms = candidates
            .filter { selected.contains($0.term) }
            .map(\.term)
        guard !terms.isEmpty else { return }

        busy = true
        defer { busy = false }

        var request = URLRequest(url: addURL)
        request.httpMethod = "POST"
        request.setValue(
            "application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type"
        )
        let encoded = terms.joined(separator: "\n")
            .addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? ""
        request.httpBody = Data("terms=\(encoded)".utf8)

        struct Response: Decodable { var added: Int }

        do {
            let (data, _) = try await URLSession.shared.data(for: request)
            let decoded = try JSONDecoder().decode(Response.self, from: data)
            status = "已加入 \(decoded.added) 个词，下一句听写就生效。"
            candidates.removeAll { selected.contains($0.term) }
            selected = []
        } catch {
            status = "加入失败：\(error.localizedDescription)"
        }
    }

    func toggle(_ term: String) {
        if selected.contains(term) {
            selected.remove(term)
        } else {
            selected.insert(term)
        }
    }
}

struct HotwordCandidatesView: View {
    @ObservedObject var model: HotwordCandidatesModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                Text("从你的听写记录里找出来的词")
                    .font(.headline)
                Text("只读本机的转写记录，不读输入框、不联网。\n"
                     + "勾中的才会进热词表 —— 不会有任何词自己加进去。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(20)

            Divider()

            if model.candidates.isEmpty {
                VStack {
                    Spacer()
                    Text(model.status)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(24)
                    Spacer()
                }
                .frame(maxWidth: .infinity)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(model.candidates) { candidate in
                            Toggle(isOn: Binding(
                                get: { model.selected.contains(candidate.term) },
                                set: { _ in model.toggle(candidate.term) }
                            )) {
                                HStack {
                                    Text(candidate.term)
                                    Spacer()
                                    Text("说过 \(candidate.count) 次")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                    .padding(20)
                }
            }

            Divider()

            HStack {
                Text(model.status)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                Spacer()
                Button("重新扫描") {
                    Task { await model.load() }
                }
                Button("加入选中的 \(model.selected.count) 个") {
                    Task { await model.add() }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(model.selected.isEmpty || model.busy)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
        }
        .frame(minWidth: 420)
        .task { await model.load() }
    }
}

@MainActor
final class HotwordCandidatesWindowController {
    private var window: NSWindow?

    func show(config: Config) {
        if let window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let model = HotwordCandidatesModel(config: config)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 460, height: 460),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "热词候选"
        window.minSize = NSSize(width: 420, height: 300)

        // 见 SettingsWindow：不清掉 sizingOptions 的话，窗口会被 SwiftUI
        // 内容的理想尺寸锁死，既拉不小也滚不动
        let hosting = NSHostingController(rootView: HotwordCandidatesView(model: model))
        hosting.sizingOptions = []
        window.contentViewController = hosting
        window.setContentSize(NSSize(width: 460, height: 460))
        window.center()
        window.isReleasedWhenClosed = false

        self.window = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}
