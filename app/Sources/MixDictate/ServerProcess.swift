import Foundation

/// 管理 Python 转写服务的子进程。
///
/// 之前要用户自己开一个终端跑 `make server`：App 退出后服务还挂着，
/// 服务崩了 App 也不知道。现在生命周期由 App 全权负责。
///
/// 启动时先探一次 /health：如果已经有服务在跑（用户手动起的、或者
/// launchd 拉起的），就直接接管，不再启第二个 —— 否则会端口冲突。
final class ServerProcess {
    enum Status {
        case stopped
        case starting
        case ready
        case failed(String)
    }

    private let config: Config
    private var process: Process?
    private var logHandle: FileHandle?

    /// 服务是不是我们自己启的。不是的话退出时不该去杀它。
    private(set) var isOwned = false

    init(config: Config) {
        self.config = config
    }

    // MARK: - 位置

    static var supportDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/MixDictate")
    }

    static var pythonURL: URL {
        supportDirectory.appendingPathComponent("venv/bin/python")
    }

    static var logURL: URL {
        supportDirectory.appendingPathComponent("logs/server.log")
    }

    // MARK: - 启动

    func start() async -> Status {
        // 已经有服务在跑就直接用，别启第二个
        if await isHealthy() {
            isOwned = false
            return .ready
        }

        guard FileManager.default.isExecutableFile(atPath: Self.pythonURL.path) else {
            return .failed("还没安装转写服务。在项目目录里跑一次 ./install.sh")
        }

        do {
            try spawn()
            isOwned = true
        } catch {
            return .failed("启动服务失败：\(error.localizedDescription)")
        }

        // 首次运行要从 Hugging Face 下模型，给足时间
        return await waitForHealth(timeout: 180)
    }

    private func spawn() throws {
        let logDirectory = Self.logURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: logDirectory, withIntermediateDirectories: true
        )
        if !FileManager.default.fileExists(atPath: Self.logURL.path) {
            FileManager.default.createFile(atPath: Self.logURL.path, contents: nil)
        }

        let handle = try FileHandle(forWritingTo: Self.logURL)
        handle.seekToEndOfFile()

        let task = Process()
        task.executableURL = Self.pythonURL
        task.arguments = ["-m", "mixdictate_server.main"]
        task.standardOutput = handle
        task.standardError = handle

        var environment = ProcessInfo.processInfo.environment
        // 不关缓冲的话日志会卡在管道里，出问题时日志文件是空的，没法排错
        environment["PYTHONUNBUFFERED"] = "1"
        environment["MIXDICTATE_MODEL"] = config.model
        task.environment = environment

        try task.run()

        process = task
        logHandle = handle
    }

    private func waitForHealth(timeout: TimeInterval) async -> Status {
        let deadline = Date().addingTimeInterval(timeout)

        while Date() < deadline {
            if await isHealthy() {
                return .ready
            }
            // 进程已经死了就别再等了，直接把退出码和日志位置报出来
            if let process, !process.isRunning {
                return .failed(
                    "服务启动后立即退出（退出码 \(process.terminationStatus)）。日志：\(Self.logURL.path)"
                )
            }
            try? await Task.sleep(nanoseconds: 500_000_000)
        }

        return .failed("服务 \(Int(timeout)) 秒内没有就绪。日志：\(Self.logURL.path)")
    }

    // MARK: - 停止

    func stop() {
        // 别人的服务不归我们管
        guard isOwned, let process, process.isRunning else { return }

        process.terminate()  // SIGTERM，让 uvicorn 正常收尾
        self.process = nil

        try? logHandle?.close()
        logHandle = nil
    }

    // MARK: - 健康检查

    func isHealthy() async -> Bool {
        var request = URLRequest(url: config.healthURL)
        request.timeoutInterval = 2

        guard
            let (data, response) = try? await URLSession.shared.data(for: request),
            let http = response as? HTTPURLResponse,
            http.statusCode == 200,
            let health = try? JSONDecoder().decode(HealthResponse.self, from: data)
        else { return false }

        return health.ok
    }
}
