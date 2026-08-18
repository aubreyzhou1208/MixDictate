import Foundation

/// 运行时配置。默认值够用；想改就在 ~/.config/mixdictate/config.json 里覆盖。
struct Config: Codable {
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
        guard
            let data = try? Data(contentsOf: path),
            let decoded = try? JSONDecoder().decode(Config.self, from: data)
        else {
            return Config()
        }
        return decoded
    }

    var transcribeURL: URL { URL(string: serverURL + "/transcribe")! }
    var healthURL: URL { URL(string: serverURL + "/health")! }
}
