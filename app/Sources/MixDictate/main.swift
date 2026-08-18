import AppKit

// 菜单栏 App：不进 Dock，不要主窗口
let delegate = AppDelegate()
let application = NSApplication.shared
application.delegate = delegate
application.setActivationPolicy(.accessory)
application.run()
