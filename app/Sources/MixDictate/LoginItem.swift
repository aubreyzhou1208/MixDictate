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

    /// 「下次登录还起不起」由 plist 在不在决定 —— 登录时 launchd 扫的就是
    /// ~/Library/LaunchAgents。job 现在加载没加载是**这一次会话**的事，
    /// 跟开机自启是两码事，拿它当开关的值会答非所问。
    static var isEnabled: Bool {
        FileManager.default.fileExists(atPath: plistURL.path)
    }

    /// launchd 现在管着的那个进程的 pid，没有就是 nil。
    ///
    /// 需要它是因为 `bootout` 会**把那个进程 SIGTERM 掉**。用户只是取消个
    /// 勾选，App 却当场退出 —— 这个代价跟他要求的事完全不成比例。
    private static var managedPID: pid_t? {
        let result = launchctl(["print", "gui/\(getuid())/\(label)"])
        guard result.status == 0 else { return nil }
        for line in result.output.split(separator: "\n") {
            let parts = line.split(separator: "=", maxSplits: 1)
            guard parts.count == 2,
                  parts[0].trimmingCharacters(in: .whitespaces) == "pid",
                  let pid = pid_t(parts[1].trimmingCharacters(in: .whitespaces))
            else { continue }
            return pid
        }
        return nil
    }

    /// launchd 管的就是当前这个进程。此时绝不能 bootout。
    private static var managesThisProcess: Bool { managedPID == getpid() }

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
            // 没有 KeepAlive。它会在 App 退出后 10 秒把它拉回来 ——
            // 于是菜单里的「退出」变成"闪一下又回来"，用户根本关不掉它。
            // 开机自启的意思是"登录时起一次"，不是"你不许退出"。
            "StandardOutPath": logDirectory.appendingPathComponent("\(label).log").path,
            "StandardErrorPath": logDirectory.appendingPathComponent("\(label).err.log").path,
        ]
        let data = try PropertyListSerialization.data(
            fromPropertyList: plist, format: .xml, options: 0)
        try data.write(to: plistURL, options: .atomic)

        // 之前被 `launchctl disable` 关过的话，plist 写回去也不会生效 ——
        // 那条禁用记录存在另一个数据库里，删 plist 清不掉它。
        _ = launchctl(["enable", "gui/\(getuid())/\(label)"])

        guard isEnabled else {
            throw Failure(message: "plist 写完了但 \(plistURL.path) 不在")
        }

        // 当前这个 App 就是 launchd 拉起来的：job 已经在了，plist 也写回去了，
        // 到此为止。再走 bootout → bootstrap 的话，第一步就把自己杀了。
        if managesThisProcess { return }

        // 让 launchd 现在就收下这份 plist —— 顺便验一遍它是能被接受的。
        // 只写文件不加载的话，写错了要到下次登录才发现，而那时候没人在看。
        // 没装过时 bootout 会失败，那不算错。
        _ = launchctl(["bootout", "gui/\(getuid())/\(label)"])
        let result = launchctl(["bootstrap", "gui/\(getuid())", plistURL.path])
        guard result.status == 0 else {
            throw Failure(message: "launchctl bootstrap 失败（\(result.status)）：\(result.output)")
        }
    }

    static func disable() throws {
        // 先删 plist。决定"下次登录还起不起"的就是这个文件，
        // 删掉它这件事就已经办完了。
        if FileManager.default.fileExists(atPath: plistURL.path) {
            try FileManager.default.removeItem(at: plistURL)
        }
        // 只有当 launchd 管的不是我们自己时才卸载 job。
        // 是自己的话 bootout 会当场把 App 关掉 —— 用户点的是"以后别自己启动"，
        // 不是"现在退出"。job 留到本次注销为止，没有 plist 就不会再回来。
        if !managesThisProcess {
            _ = launchctl(["bootout", "gui/\(getuid())/\(label)"])
        }

        guard !isEnabled else {
            throw Failure(message: "删不掉 \(plistURL.path)")
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
