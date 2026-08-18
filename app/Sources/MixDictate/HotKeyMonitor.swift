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
    private let trackedFlag: NSEvent.ModifierFlags
    private let onPress: () -> Void
    private let onRelease: () -> Void

    init(keyCode: UInt16, onPress: @escaping () -> Void, onRelease: @escaping () -> Void) {
        self.keyCode = keyCode
        self.trackedFlag = Self.flag(for: keyCode)
        self.onPress = onPress
        self.onRelease = onRelease
    }

    /// 每个修饰键对应哪个 flag。必须按键区分，不能笼统看"有没有修饰键按着" ——
    /// 否则用户按着 Command 再按右 Option 时，松开右 Option 的那一刻
    /// modifierFlags 里仍留着 .command，会被误判成"还按着"，录音就永远停不下来。
    private static func flag(for keyCode: UInt16) -> NSEvent.ModifierFlags {
        switch keyCode {
        case 58, 61: return .option    // 左 / 右 Option
        case 54, 55: return .command   // 右 / 左 Command
        case 59, 62: return .control   // 左 / 右 Control
        case 56, 60: return .shift     // 左 / 右 Shift
        case 63:     return .function
        default:     return .option
        }
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

        let active = event.modifierFlags
            .intersection(.deviceIndependentFlagsMask)
            .contains(trackedFlag)

        if active, !isDown {
            isDown = true
            onPress()
        } else if !active, isDown {
            isDown = false
            onRelease()
        }
    }
}
