import AppKit

/// 观察用户对刚插入的那段文字做了什么修改，学成热词。
///
/// ## 为什么值得做
///
/// 转写记录里挖词只能看到"这个词你说得多"，看不到"这个词它一直听错"。
/// 而真正需要进热词表的恰恰是后者 —— 你每次都要手动改的那个词。
/// 你改了什么，是唯一能区分这两件事的信号。
///
/// ## 边界
///
/// 这是整个项目里唯一会去碰输入框内容的地方，所以口子必须尽量小：
///
/// · **只读我们自己写进去的那一段。** 用 kAXStringForRange 按范围取，
///   向系统要的就只有这一段。承诺落在接口这一层，而不是"读回全文之后
///   我们自觉不看别的"。
/// · **控件不支持按范围读就放弃这次学习**，绝不退回去读全文。
/// · **默认关闭**，要在设置里主动打开。
/// · 学到的东西只存在本机，不联网。
///
/// ## 为什么只认小改动
///
/// 改一两个词是"它听错了"，整段重写是"我改主意了" —— 后者不该被学成
/// 听写错误。所以变化太长就丢弃。
@MainActor
final class CorrectionWatcher {
    private let config: Config

    /// 刚插入的那段文字，和它在输入框里的起点
    private var inserted: String?
    private var location: Int?
    private var task: Task<Void, Never>?

    /// 真的写进词表时通知外面。用回调而不是系统通知：系统通知要申请
    /// 授权、macOS 11 之后旧接口也废弃了，而这里要的只是"让人看见"。
    var onLearned: ((String, String) -> Void)?

    init(config: Config) {
        self.config = config
    }

    /// 文字刚写进输入框时调用。
    func noteInsertion(_ text: String) {
        cancel()
        guard config.learnCorrections, !text.isEmpty else { return }

        // 插入点在光标之前，所以起点 = 当前光标 - 插入长度
        guard let caret = TextInjector.caretOffset() else { return }
        let start = caret - text.count
        guard start >= 0 else { return }

        inserted = text
        location = start

        task = Task { @MainActor [weak self] in
            // 等一会儿再看。改字要时间，读太早只会看到原样。
            try? await Task.sleep(nanoseconds: 6_000_000_000)
            guard !Task.isCancelled else { return }
            self?.checkForCorrection()
        }
    }

    func cancel() {
        task?.cancel()
        task = nil
        inserted = nil
        location = nil
    }

    private func checkForCorrection() {
        guard let original = inserted, let start = location else { return }
        defer { cancel() }

        // 多读一点，因为改完之后这一段可能变长了。
        // 仍然只是"我们那一段附近"，不是整个输入框。
        let span = original.count + 16
        guard let current = TextInjector.readRange(location: start, length: span) else {
            // 控件不支持按范围读。放弃，不退回去读全文。
            return
        }

        guard let pair = Self.correction(from: original, to: current) else { return }

        Task { @MainActor in
            await report(wrong: pair.wrong, right: pair.right)
        }
    }

    /// 从"我们写的"和"现在是的"里抠出被改掉的那一小段。
    ///
    /// 掐头去尾取公共部分，剩下的就是差异。两边都得非空 ——
    /// 纯删除（右边空）是"这段我不要了"，不是"听错了"。
    static func correction(from original: String, to current: String) -> (wrong: String, right: String)? {
        let old = Array(original)
        var new = Array(current)

        // current 是多读出来的，尾巴上可能带着本来就在那儿的内容。
        // 只在它确实以 old 的尾巴结束时才对齐，否则不做假设。
        guard old != new else { return nil }

        var head = 0
        while head < old.count, head < new.count, old[head] == new[head] {
            head += 1
        }

        var tail = 0
        while tail < old.count - head, tail < new.count - head,
              old[old.count - 1 - tail] == new[new.count - 1 - tail] {
            tail += 1
        }

        let wrong = String(old[head..<(old.count - tail)])
        let right = String(new[head..<(new.count - tail)])
        new = []

        guard !wrong.isEmpty, !right.isEmpty else { return nil }
        // 改一两个词是"它听错了"，大段重写是"我改主意了"
        guard wrong.count <= 12, right.count <= 12 else { return nil }
        return (wrong, right)
    }

    private func report(wrong: String, right: String) async {
        guard let url = URL(string: config.serverURL)?
            .appendingPathComponent("hotwords/observe") else { return }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(
            "application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type"
        )
        func encode(_ value: String) -> String {
            value.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? ""
        }
        request.httpBody = Data("wrong=\(encode(wrong))&right=\(encode(right))".utf8)

        struct Response: Decodable {
            var count: Int
            var learned: Bool
        }

        guard let (data, _) = try? await URLSession.shared.data(for: request),
              let decoded = try? JSONDecoder().decode(Response.self, from: data)
        else { return }

        NSLog("MixDictate: 观察到纠正 %@ → %@（第 %d 次）", wrong, right, decoded.count)

        // 只有真的入表了才打扰用户。每次改字都提示一下会很烦，
        // 而"它自己改了我的词表"这件事必须让人知道。
        guard decoded.learned else { return }
        onLearned?(wrong, right)
    }
}
