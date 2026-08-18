import Foundation

/// 运行时配置。存在 ~/.config/mixdictate/config.json，设置界面直接改这个文件。
struct Config {
    /// 按住不放的说话键。61 = 右 Option。
    /// 右 Command(54) 也常见，但它跟很多 App 的快捷键冲突，所以默认用右 Option。
    var pushToTalkKeyCode: UInt16 = 61
    var serverURL: String = "http://127.0.0.1:8765"

    /// 去掉"嗯""呃"这类口语填充词
    var stripFillers: Bool = true

    /// 中文标点转全角。写代码时可能更想要半角，所以留成开关。
    var fullwidthPunctuation: Bool = true

    /// 短于这个时长的录音直接丢弃 —— 多半是误触
    var minimumDurationSeconds: Double = 0.3

    /// 录音时在屏幕上显示实时转写结果
    var showLiveOverlay: Bool = true

    /// 实时结果的刷新间隔。太短会让模型一直在跑上一段音频，
    /// 反而拖慢松手后的最终结果。
    var partialIntervalSeconds: Double = 1.2

    /// 边说边把文字直接写进输入框，不用浮层也不用等松手。
    /// 代价见设置界面里的说明 —— 默认关闭。
    var liveInsertion: Bool = false

    /// 文字送进输入框的方式。粘贴最快，逐字输入兼容性更好。
    /// 安全输入模式下两者都会被系统拦截，那时会自动改走辅助功能接口。
    var insertionMethod: String = InsertionMethod.paste.rawValue

    /// 改这个要重启转写服务才生效
    var model: String = "Qwen/Qwen3-ASR-0.6B"

    static let path = FileManager.default
        .homeDirectoryForCurrentUser
        .appendingPathComponent(".config/mixdictate/config.json")

    /// 配置文件的修改时间。App 靠它发现外部改动 —— 菜单栏图标常常
    /// 找不到，命令行改配置必须能立刻生效。
    static func modificationDate() -> Date? {
        try? FileManager.default
            .attributesOfItem(atPath: path.path)[.modificationDate] as? Date
    }

    static func load() -> Config {
        guard let data = try? Data(contentsOf: path) else { return Config() }
        return (try? JSONDecoder().decode(Config.self, from: data)) ?? Config()
    }

    func save() throws {
        try FileManager.default.createDirectory(
            at: Self.path.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(self).write(to: Self.path, options: .atomic)
    }

    /// serverURL 写坏了不该让整个 App 崩掉，退回默认地址
    private var baseURL: URL {
        URL(string: serverURL) ?? URL(string: "http://127.0.0.1:8765")!
    }

    /// 配置里写了个不认识的值时退回默认，不要让听写整个失效
    var resolvedInsertionMethod: InsertionMethod {
        InsertionMethod(rawValue: insertionMethod) ?? .paste
    }

    var transcribeURL: URL { baseURL.appendingPathComponent("transcribe") }
    var healthURL: URL { baseURL.appendingPathComponent("health") }
}

// 手写解码而不是用合成的：合成的 init(from:) 要求 JSON 里每个键都存在，
// 只写了一个 pushToTalkKeyCode 的配置文件会整份解码失败，然后被 try? 吞掉 ——
// 表现就是"我明明改了配置却完全没生效"。decodeIfPresent 才是想要的语义。
// 这条在加字段之后更重要：老配置文件不能因为缺新字段就整份失效。
extension Config: Codable {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let fallback = Config()
        pushToTalkKeyCode = try c.decodeIfPresent(UInt16.self, forKey: .pushToTalkKeyCode)
            ?? fallback.pushToTalkKeyCode
        serverURL = try c.decodeIfPresent(String.self, forKey: .serverURL)
            ?? fallback.serverURL
        stripFillers = try c.decodeIfPresent(Bool.self, forKey: .stripFillers)
            ?? fallback.stripFillers
        fullwidthPunctuation = try c.decodeIfPresent(Bool.self, forKey: .fullwidthPunctuation)
            ?? fallback.fullwidthPunctuation
        minimumDurationSeconds = try c.decodeIfPresent(Double.self, forKey: .minimumDurationSeconds)
            ?? fallback.minimumDurationSeconds
        showLiveOverlay = try c.decodeIfPresent(Bool.self, forKey: .showLiveOverlay)
            ?? fallback.showLiveOverlay
        partialIntervalSeconds = try c.decodeIfPresent(Double.self, forKey: .partialIntervalSeconds)
            ?? fallback.partialIntervalSeconds
        liveInsertion = try c.decodeIfPresent(Bool.self, forKey: .liveInsertion)
            ?? fallback.liveInsertion
        insertionMethod = try c.decodeIfPresent(String.self, forKey: .insertionMethod)
            ?? fallback.insertionMethod
        model = try c.decodeIfPresent(String.self, forKey: .model)
            ?? fallback.model
    }
}

/// 可选的模型。0.6B 够日常用，1.7B 更准但更吃内存和时间。
enum ASRModel: String, CaseIterable {
    case small = "Qwen/Qwen3-ASR-0.6B"
    case large = "Qwen/Qwen3-ASR-1.7B"

    var label: String {
        switch self {
        case .small: return "0.6B — 快（推荐）"
        case .large: return "1.7B — 更准，慢一些"
        }
    }
}
