import AppKit

/// 同一时刻只允许一个 MixDictate：两份的话有两套热键监听、两个转写服务抢
/// 同一个端口，而两个菜单栏图标长得一模一样，从外面完全看不出来。
///
/// 但"已经有一个在跑"不等于"那一个还能用"。更新时 install.sh 会把
/// /Applications 里的 bundle 整个换掉，而在那之前 launchd 可能已经把旧版
/// 拉起来了 —— 那个进程还活着，跑的却是被换走的代码，bundle 也不在了。
/// 让新版给这种僵尸让路，结果就是更新完之后跑的还是旧的那一份。
///
/// 判据：**启动时间比它要跑的那个二进制还早的实例，跑的一定是旧代码。**
/// 这种直接换掉；真正跟我们同代码的实例才值得让路。
///
/// **这个检查必须在 `NSApplication.shared` 之后跑。** 它用的
/// `NSRunningApplication` 是 AppKit 的东西，而 AppKit 要求 `NSApplication`
/// 是进程里第一个被初始化的 AppKit 对象 —— 抢在它前面碰别的，App 跟窗口
/// 服务器的注册就可能是半吊子状态，表现出来是菜单栏项建得出来却没人给它
/// 位置。所以它现在从 `applicationWillFinishLaunching` 里调用。
@MainActor
enum SingleInstance {
    /// 返回 true 表示这一份该退出，让给已经在跑的那个。
    static func shouldYield() -> Bool {
        guard let identifier = Bundle.main.bundleIdentifier else { return false }
        let mine = NSRunningApplication.current
        let binaryDate = Bundle.main.executableURL
            .flatMap { try? $0.resourceValues(forKeys: [.contentModificationDateKey]) }?
            .contentModificationDate

        var stale: [NSRunningApplication] = []
        for other in NSRunningApplication.runningApplications(withBundleIdentifier: identifier)
        where other.processIdentifier != mine.processIdentifier && !other.isTerminated {
            if let launched = other.launchDate, let binaryDate, launched < binaryDate {
                stale.append(other)
                continue
            }
            // 比我们晚起来的：该退出的是它，不是我们。
            if let theirs = other.launchDate, let ours = mine.launchDate, theirs >= ours {
                continue
            }
            NSLog("MixDictate: 已经有一个在运行，这一份退出")
            return true
        }

        guard !stale.isEmpty else { return false }

        NSLog("MixDictate: 发现 \(stale.count) 个跑着旧代码的实例，请它们退出")
        stale.forEach { $0.terminate() }

        // 等它真的走。terminate() 只是发个信号 —— 没等就往下走的话，
        // 菜单栏和热键会跟一个还没死透的进程抢。
        //
        // 判断"还在不在"用 kill(pid, 0) 而不是 isTerminated：isTerminated 要靠
        // 工作区通知来更新，而这时候主 run loop 还没开始转，它可能一直停在
        // 旧值上，把这里变成死等。EPERM 表示进程还在，只是我们没权限发信号。
        func alive(_ app: NSRunningApplication) -> Bool {
            kill(app.processIdentifier, 0) == 0 || errno == EPERM
        }
        var waited = 0
        while waited < 20, stale.contains(where: alive) {
            Thread.sleep(forTimeInterval: 0.1)
            waited += 1
        }
        stale.filter(alive).forEach { $0.forceTerminate() }
        return false
    }
}
