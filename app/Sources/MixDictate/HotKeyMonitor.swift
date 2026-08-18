import AppKit

/// 监听"按住说话"键。默认右 Option，按下开始录，松开结束。
///
/// 用 flagsChanged 事件而不是注册热键，是因为修饰键本身没有 keyDown/keyUp，
/// 状态变化只能从 flagsChanged 里读。
final class HotKeyMonitor {
    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var isDown = false

    private let keyCode: UInt16
    private let onPress: () -> Void
    private let onRelease: () -> Void

    init(keyCode: UInt16, onPress: @escaping () -> Void, onRelease: @escaping () -> Void) {
        self.keyCode = keyCode
        self.onPress = onPress
        self.onRelease = onRelease
    }

    func start() {
        // 全局监听（其他 App 在前台时）
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            self?.handle(event)
        }
        // 本地监听（自己在前台时；全局监听收不到自己的事件）
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            self?.handle(event)
            return event
        }
    }

    func stop() {
        [globalMonitor, localMonitor].compactMap { $0 }.forEach(NSEvent.removeMonitor)
        globalMonitor = nil
        localMonitor = nil
    }

    private func handle(_ event: NSEvent) {
        guard event.keyCode == keyCode else { return }

        // 修饰键按下时对应的 flag 会出现在 modifierFlags 里，松开时消失。
        // 用 deviceIndependentFlagsMask 过滤掉底层的左右键区分位。
        let active = !event.modifierFlags
            .intersection(.deviceIndependentFlagsMask)
            .isEmpty

        if active, !isDown {
            isDown = true
            onPress()
        } else if !active, isDown {
            isDown = false
            onRelease()
        }
    }
}
