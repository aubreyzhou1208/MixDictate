import AppKit

// NSApplication.delegate 是 weak 的。delegate 一旦被释放，所有回调
// （包括热键监听）都会静默失效 —— App 还在菜单栏挂着，但按键完全没反应。
// 所以这里必须自己留一份强引用。
private var retainedDelegate: AppDelegate?

// main.swift 的顶层代码在 Swift 5 语言模式下不是 main actor 隔离的，
// 而 AppDelegate 标了 @MainActor（它要碰 NSStatusItem 这些 UI 状态）。
// 程序入口本来就跑在主线程上，用 assumeIsolated 把这个事实告诉编译器 ——
// 比给 AppDelegate 摘掉 @MainActor 安全得多。
// 同一时刻只允许一个 MixDictate。
//
// 开机自启是 launchd 按 RunAtLoad 拉起来的，而"在设置里勾上开机自启"这个
// 动作本身也会让 launchd 立刻拉一份 —— 于是菜单栏出现两个图标，两套热键
// 监听，两个转写服务抢同一个端口。用户双击一下 App 也是同样的结果。
//
// 后来的那个直接退出：先到的那个正被人用着，把它换掉毫无道理。
MainActor.assumeIsolated {
    if let identifier = Bundle.main.bundleIdentifier {
        let mine = NSRunningApplication.current
        let others = NSRunningApplication
            .runningApplications(withBundleIdentifier: identifier)
            .filter { $0.processIdentifier != mine.processIdentifier }
        let launchedEarlier = others.contains { other in
            guard let theirs = other.launchDate else { return true }
            guard let ours = mine.launchDate else { return true }
            return theirs < ours
        }
        if launchedEarlier {
            NSLog("MixDictate 已经在运行了，这一份退出")
            exit(0)
        }
    }

    let delegate = AppDelegate()
    retainedDelegate = delegate

    // 菜单栏 App：不进 Dock，不要主窗口
    let application = NSApplication.shared
    application.delegate = delegate
    application.setActivationPolicy(.accessory)
    application.run()
}
