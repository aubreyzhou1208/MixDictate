import AppKit

// NSApplication.delegate 是 weak 的。delegate 一旦被释放，所有回调
// （包括热键监听）都会静默失效 —— App 还在菜单栏挂着，但按键完全没反应。
// 所以这里必须自己留一份强引用。
private var retainedDelegate: AppDelegate?

// main.swift 的顶层代码在 Swift 5 语言模式下不是 main actor 隔离的，
// 而 AppDelegate 标了 @MainActor（它要碰 NSStatusItem 这些 UI 状态）。
// 程序入口本来就跑在主线程上，用 assumeIsolated 把这个事实告诉编译器 ——
// 比给 AppDelegate 摘掉 @MainActor 安全得多。
MainActor.assumeIsolated {
    let delegate = AppDelegate()
    retainedDelegate = delegate

    // 菜单栏 App：不进 Dock，不要主窗口
    let application = NSApplication.shared
    application.delegate = delegate
    application.setActivationPolicy(.accessory)
    application.run()
}
