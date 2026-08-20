import Foundation

/// 开机自启。跟 `scripts/autostart.sh` 装的是**同一个** LaunchAgent
/// （同一个 label、同一个 plist 路径），所以命令行和设置界面看到的永远是
/// 同一件事，不会各说各话。
///
/// 没有用 `SMAppService`：它要求正经的开发者签名，而这个 App 是 ad-hoc 签的，
/// 注册失败时给的错误又很含糊。LaunchAgent 这条路能自己检查结果，也能把
/// 失败原因原样说出来 —— 这个项目里所有的坑都是"没报错但没生效"。
enum LoginItem {
    static let label = "dev.mixdictate.app"

    private static var plistURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents/\(label).plist")
    }

    private static var logDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/mixdictate")
    }

    /// 开机要拉起哪个二进制。优先 /Applications 里那份 —— 装到那儿才是
    /// 用户日常在用的那个；开发时直接跑构建产物的话就用当前这份。
    static var executablePath: String {
        let installed = "/Applications/MixDictate.app/Contents/MacOS/MixDictate"
        if FileManager.default.isExecutableFile(atPath: installed) { return installed }
        return Bundle.main.executableURL?.path ?? installed
    }

    /// 真的问一遍 launchd，而不是看 plist 在不在。
    /// 文件还在但没加载（比如手动删过 job）时，"文件在"会骗人。
    static var isEnabled: Bool {
        guard FileManager.default.fileExists(atPath: plistURL.path) else { return false }
        return launchctl(["print", "gui/\(getuid())/\(label)"]).status == 0
    }

    struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    static func enable() throws {
        let binary = executablePath
        guard FileManager.default.isExecutableFile(atPath: binary) else {
            throw Failure(message: "找不到可执行文件 \(binary) —— 先跑一次 ./install.sh")
        }

        try FileManager.default.createDirectory(
            at: plistURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: logDirectory, withIntermediateDirectories: true)

        let plist: [String: Any] = [
            "Label": label,
            "ProgramArguments": [binary],
            "RunAtLoad": true,
            // 崩了自动拉起，10 秒节流，避免出问题时疯狂重启刷屏
            "KeepAlive": true,
            "ThrottleInterval": 10,
            "StandardOutPath": logDirectory.appendingPathComponent("\(label).log").path,
            "StandardErrorPath": logDirectory.appendingPathComponent("\(label).err.log").path,
        ]
        let data = try PropertyListSerialization.data(
            fromPropertyList: plist, format: .xml, options: 0)
        try data.write(to: plistURL, options: .atomic)

        // 没装过时 bootout 会失败，那不算错
        _ = launchctl(["bootout", "gui/\(getuid())/\(label)"])
        let result = launchctl(["bootstrap", "gui/\(getuid())", plistURL.path])
        guard result.status == 0 else {
            throw Failure(message: "launchctl bootstrap 失败（\(result.status)）：\(result.output)")
        }
        // 装完复查一遍。launchctl 返回 0 不代表 job 真的在 ——
        // 这个项目里"没报错但没生效"出现过太多次了。
        guard isEnabled else {
            throw Failure(message: "已经写好 \(plistURL.path)，但 launchd 里查不到这个任务")
        }
    }

    static func disable() throws {
        _ = launchctl(["bootout", "gui/\(getuid())/\(label)"])
        if FileManager.default.fileExists(atPath: plistURL.path) {
            try FileManager.default.removeItem(at: plistURL)
        }
        guard !isEnabled else {
            throw Failure(message: "卸载没生效，launchd 里还留着这个任务")
        }
    }

    private static func launchctl(_ arguments: [String]) -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do {
            try process.run()
        } catch {
            return (-1, error.localizedDescription)
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let text = String(data: data, encoding: .utf8) ?? ""
        return (process.terminationStatus,
                text.trimmingCharacters(in: .whitespacesAndNewlines))
    }
}
