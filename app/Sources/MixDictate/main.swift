import AppKit

// NSApplication.delegate 是 weak 的。delegate 一旦被释放，所有回调
// （包括热键监听）都会静默失效 —— App 还在菜单栏挂着，但按键完全没反应。
// 所以这里必须自己留一份强引用。
private var retainedDelegate: AppDelegate?

// 同一时刻只允许一个 MixDictate：两份的话有两套热键监听、两个转写服务抢
// 同一个端口，而两个菜单栏图标长得一模一样，从外面完全看不出来。
//
// 但"已经有一个在跑"不等于"那一个还能用"。更新时 install.sh 会把
// /Applications 里的 bundle 整个换掉，而在那之前 launchd 可能已经把旧版
// 拉起来了 —— 那个进程还活着，跑的却是被换走的代码，bundle 也不在了。
// 让新版给这种僵尸让路，结果就是更新完之后跑的还是旧的那一份。
//
// 判据：**启动时间比它要跑的那个二进制还早的实例，跑的一定是旧代码。**
// 这种直接换掉；真正跟我们同代码的实例才值得让路。
private func makeWayForRunningInstance() -> Bool {
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
        // 跟我们同一份代码，而且比我们早 —— 它正被人用着，让给它。
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
    // 判断"还在不在"用 kill(pid, 0) 而不是 isTerminated：这时候
    // NSApplication 还没起来，主 run loop 也没在转，而 isTerminated 要靠
    // 工作区通知来更新 —— 它可能一直停在旧值上，把这里变成死等。
    // EPERM 表示进程还在，只是我们没权限给它发信号。
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

// main.swift 的顶层代码在 Swift 5 语言模式下不是 main actor 隔离的，
// 而 AppDelegate 标了 @MainActor（它要碰 NSStatusItem 这些 UI 状态）。
// 程序入口本来就跑在主线程上，用 assumeIsolated 把这个事实告诉编译器 ——
// 比给 AppDelegate 摘掉 @MainActor 安全得多。
MainActor.assumeIsolated {
    if makeWayForRunningInstance() { exit(0) }

    let delegate = AppDelegate()
    retainedDelegate = delegate

    // 菜单栏 App：不进 Dock，不要主窗口
    let application = NSApplication.shared
    application.delegate = delegate
    application.setActivationPolicy(.accessory)
    application.run()
}
