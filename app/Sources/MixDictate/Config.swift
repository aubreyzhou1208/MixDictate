import Foundation

/// 运行时配置。默认值够用；想改就在 ~/.config/mixdictate/config.json 里覆盖。
struct Config {
    /// 按住不放的说话键。61 = 右 Option。
    /// 右 Command(54) 也常见，但它跟很多 App 的快捷键冲突，所以默认用右 Option。
    var pushToTalkKeyCode: UInt16 = 61
    var serverURL: String = "http://127.0.0.1:8765"
    var stripFillers: Bool = true
    /// 短于这个时长的录音直接丢弃 —— 多半是误触
    var minimumDurationSeconds: Double = 0.3

    static let path = FileManager.default
        .homeDirectoryForCurrentUser
        .appendingPathComponent(".config/mixdictate/config.json")

    static func load() -> Config {
        guard let data = try? Data(contentsOf: path) else { return Config() }
        return (try? JSONDecoder().decode(Config.self, from: data)) ?? Config()
    }

    /// serverURL 写坏了不该让整个 App 崩掉，退回默认地址
    private var baseURL: URL {
        URL(string: serverURL) ?? URL(string: "http://127.0.0.1:8765")!
    }

    var transcribeURL: URL { baseURL.appendingPathComponent("transcribe") }
    var healthURL: URL { baseURL.appendingPathComponent("health") }
}

// 手写解码而不是用合成的：合成的 init(from:) 要求 JSON 里每个键都存在，
// 只写了一个 pushToTalkKeyCode 的配置文件会整份解码失败，然后被 try? 吞掉 ——
// 表现就是"我明明改了配置却完全没生效"。decodeIfPresent 才是想要的语义。
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
        minimumDurationSeconds = try c.decodeIfPresent(Double.self, forKey: .minimumDurationSeconds)
            ?? fallback.minimumDurationSeconds
    }
}
