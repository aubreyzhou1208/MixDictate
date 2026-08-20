import AppKit
import ApplicationServices
import Carbon
import CoreGraphics

/// 文字送进去用的方式。三种各有盲区，所以要按顺序降级。
enum InsertionMethod: String, CaseIterable {
    /// 剪贴板 + 合成 Cmd+V。最快，长文本也是一瞬间，绝大多数 App 都支持。
    case paste
    /// 合成 Unicode 按键，等价于"把字一个个敲进去"。
    /// 少数拦截粘贴的 App 只认这个。
    case typing

    var label: String {
        switch self {
        case .paste:  return "粘贴（快，推荐）"
        case .typing: return "逐字输入（慢，兼容性更好）"
        }
    }
}

enum InjectionResult {
    case inserted(InsertionMethod)
    /// 通过辅助功能接口直接写进了输入框（安全输入模式下唯一能用的路）
    case insertedViaAccessibility
    /// 没有辅助功能权限
    case needsAccessibility
    /// 安全输入模式挡着，而且辅助功能接口也写不进去
    case blockedBySecureInput
}

/// 把文字送进当前光标所在的输入框。
///
/// 单一机制做不到"任何地方都能输入"，所以按顺序降级：
///
///   1. 安全输入模式开着时 —— 系统会拦截**一切**合成按键，
///      这时唯一的路是辅助功能接口，直接往聚焦的控件里写。
///   2. 正常情况 —— 剪贴板 + 合成 Cmd+V。最快，长文本也是一瞬间。
///   3. 用户在设置里选了逐字输入 —— 合成 Unicode 按键。
///      少数拦截粘贴的 App 只认这个。
enum TextInjector {
    private static let vKeyCode: CGKeyCode = 9
    private static let deleteKeyCode: CGKeyCode = 51

    /// 所有合成输入都排在这一条队列上。
    ///
    /// **必须串行**：两次改写要是交错发出去，退格就会删到另一次刚打进去的
    /// 字上面。**也必须离开主线程**：事件之间要留间隔（见下面），
    /// 在主线程上 sleep 会把浮层和定时器一起卡住。
    private static let inputQueue = DispatchQueue(label: "dev.mixdictate.input")

    @discardableResult
    static func insert(_ text: String, method: InsertionMethod = .paste) -> InjectionResult {
        guard AXIsProcessTrusted() else {
            // 权限缺失时也先把文字放进剪贴板，用户至少能自己 Cmd+V
            copyToPasteboard(text)
            return .needsAccessibility
        }

        // 安全输入模式下合成按键一律无效，先走辅助功能接口
        if IsSecureEventInputEnabled() {
            if insertViaAccessibility(text) {
                return .insertedViaAccessibility
            }
            copyToPasteboard(text)
            return .blockedBySecureInput
        }

        switch method {
        case .paste:
            pasteViaClipboard(text)
        case .typing:
            // 事件之间有间隔，长文本会花上百毫秒 —— 不能在主线程上等
            inputQueue.async { typeUnicode(text) }
        }
        return .inserted(method)
    }

    // MARK: - 剪贴板 + Cmd+V

    private static func pasteViaClipboard(_ text: String) {
        let pasteboard = NSPasteboard.general
        let previous = pasteboard.string(forType: .string)
        copyToPasteboard(text)

        // 给一点时间：用户刚松开说话键，修饰键状态需要先落定，
        // 否则合成的 Cmd+V 可能被残留的 Option 污染成别的快捷键。
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.06) {
            postPaste()

            // 粘贴是异步的，等目标 App 真正读完剪贴板再还原
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                pasteboard.clearContents()
                if let previous {
                    pasteboard.setString(previous, forType: .string)
                }
            }
        }
    }

    private static func postPaste() {
        let source = CGEventSource(stateID: .combinedSessionState)

        guard
            let down = CGEvent(keyboardEventSource: source, virtualKey: vKeyCode, keyDown: true),
            let up = CGEvent(keyboardEventSource: source, virtualKey: vKeyCode, keyDown: false)
        else { return }

        down.flags = .maskCommand
        up.flags = .maskCommand

        // 投递到 HID 层。用 .cgAnnotatedSessionEventTap 的话不少 App
        // 收不到合成事件 —— 表现又是"按了没反应"。
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
    }

    // MARK: - 逐字输入

    /// 两个合成按键事件之间至少隔这么久。
    ///
    /// **不留间隔会丢事件。** 目标 App 的事件队列被紧循环灌满时会丢弃或
    /// 重排合成事件，这是 CGEvent 的老问题。而实时写入对"已经写进去多少字"
    /// 的记忆，是照着**发出去的事件**算的 —— 丢一个事件这份记忆就永久偏了，
    /// 之后每次改写都在错误的基础上退删，越改越歪。
    ///
    /// 表现是"整理之后吞字"：完整重转的结果跟拼接出来的实时文本差得最多，
    /// 所以那一次改动最大，积累的偏差正好在那里爆出来。
    private static let eventIntervalMicroseconds: useconds_t = 1_200

    /// 退格发完到开始打字之间多等一会儿。这两批事件语义相反，
    /// 混在一起被处理的话，打进去的字会落在还没删完的位置上。
    private static let settleMicroseconds: useconds_t = 12_000

    /// 合成携带 Unicode 字符的按键事件，等价于把字敲进去。
    /// 不碰剪贴板，也不依赖目标 App 支持粘贴。
    private static func typeUnicode(_ text: String) {
        let source = CGEventSource(stateID: .combinedSessionState)
        let units = Array(text.utf16)

        // 一次事件塞太多字符有的 App 会截断，切成小块更稳
        let chunkSize = 16
        var index = 0

        while index < units.count {
            let end = min(index + chunkSize, units.count)
            var chunk = Array(units[index..<end])
            index = end

            guard
                let down = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true),
                let up = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false)
            else { continue }

            down.keyboardSetUnicodeString(stringLength: chunk.count, unicodeString: &chunk)
            up.keyboardSetUnicodeString(stringLength: chunk.count, unicodeString: &chunk)
            down.post(tap: .cghidEventTap)
            up.post(tap: .cghidEventTap)
            usleep(eventIntervalMicroseconds)
        }
    }

    /// 退掉尾巴再打新的，整批排进输入队列。
    ///
    /// 退格和打字必须是**同一个任务**：分成两次派发的话，中间可能插进
    /// 另一次改写，退格就删到别人的字上了。两批之间也要留安顿时间，
    /// 它们语义相反，混在一起处理会让新字落在还没删完的位置上。
    static func replaceTail(deleting count: Int, with text: String) {
        guard count > 0 || !text.isEmpty else { return }
        inputQueue.async {
            if count > 0 {
                sendBackspaces(count)
                usleep(settleMicroseconds)
            }
            if !text.isEmpty {
                typeUnicode(text)
            }
        }
    }

    /// 连发退格。只应该在输入队列上调用 —— 它会 sleep。
    private static func sendBackspaces(_ count: Int) {
        guard count > 0 else { return }
        let source = CGEventSource(stateID: .combinedSessionState)

        for _ in 0..<count {
            guard
                let down = CGEvent(
                    keyboardEventSource: source, virtualKey: deleteKeyCode, keyDown: true
                ),
                let up = CGEvent(
                    keyboardEventSource: source, virtualKey: deleteKeyCode, keyDown: false
                )
            else { return }
            down.post(tap: .cghidEventTap)
            up.post(tap: .cghidEventTap)
            usleep(eventIntervalMicroseconds)
        }
    }

    // MARK: - 辅助功能接口直写

    /// 直接把文字写进当前聚焦的控件，不经过任何按键事件 ——
    /// 所以安全输入模式拦不住它。
    ///
    /// 代价是覆盖面比粘贴窄：终端、部分 Electron App 的文本视图
    /// 不支持这个属性。所以只在合成按键行不通时才用。
    private static func insertViaAccessibility(_ text: String) -> Bool {
        let system = AXUIElementCreateSystemWide()

        var focused: CFTypeRef?
        guard
            AXUIElementCopyAttributeValue(
                system, kAXFocusedUIElementAttribute as CFString, &focused
            ) == .success,
            let element = focused,
            CFGetTypeID(element) == AXUIElementGetTypeID()
        else { return false }

        // 设置"选中的文字"等价于在光标处插入：没有选区时就是纯插入，
        // 有选区时替换掉它 —— 跟真的敲字行为一致。
        let target = element as! AXUIElement
        let status = AXUIElementSetAttributeValue(
            target, kAXSelectedTextAttribute as CFString, text as CFString
        )
        return status == .success
    }

    // MARK: - 杂项

    // MARK: - 读回我们自己写进去的那一段

    /// 当前输入框里，光标之前的插入点位置。插入完立刻取一次，
    /// 之后靠它算出"我们写的那一段"在哪儿。
    static func caretOffset() -> Int? {
        guard let element = focusedElement() else { return nil }

        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element, kAXSelectedTextRangeAttribute as CFString, &value
        ) == .success, let raw = value, CFGetTypeID(raw) == AXValueGetTypeID() else {
            return nil
        }

        var range = CFRange()
        guard AXValueGetValue(raw as! AXValue, .cfRange, &range) else { return nil }
        return range.location
    }

    /// 只读指定范围内的文字。
    ///
    /// **刻意不去读整个输入框。** 用 kAXStringForRange 这个带参数的属性，
    /// 向系统要的就只有这一段 —— 承诺"只看我们自己写的那一段"必须落在
    /// 接口这一层，而不是"读回来之后我们自觉不看别的"。
    ///
    /// 有些控件不支持这个属性。那就放弃这次学习，**不退回去读全文**。
    static func readRange(location: Int, length: Int) -> String? {
        guard location >= 0, length > 0, let element = focusedElement() else {
            return nil
        }

        var range = CFRange(location: location, length: length)
        guard let rangeValue = AXValueCreate(.cfRange, &range) else { return nil }

        var value: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(
            element,
            kAXStringForRangeParameterizedAttribute as CFString,
            rangeValue,
            &value
        ) == .success else { return nil }

        return value as? String
    }

    /// 开始听写时记下焦点在哪儿。
    ///
    /// 听写要好几秒，这期间用户完全可能点到别的地方去。不比对的话，
    /// 文字会**落进另一个输入框**，而用户以为它丢了。
    struct FocusSnapshot {
        let pid: pid_t
        let element: AXUIElement?

        /// 现在的焦点还是当初那个吗
        func isCurrent() -> Bool {
            let now = NSWorkspace.shared.frontmostApplication?.processIdentifier ?? -1
            guard now == pid else { return false }
            // 拿不到具体控件时只比 App —— 比不了不代表要拦，
            // 那样会在很多不支持辅助功能查询的 App 里把听写整个废掉
            guard let element, let current = focusedElement() else { return true }
            return CFEqual(element, current)
        }
    }

    static func focusSnapshot() -> FocusSnapshot {
        FocusSnapshot(
            pid: NSWorkspace.shared.frontmostApplication?.processIdentifier ?? -1,
            element: focusedElement()
        )
    }

    /// 读回光标**前面**的 count 个字符。
    ///
    /// 用来在退格之前确认"要删的这一段确实是我们自己写的"。读不到就返回 nil，
    /// 调用方要按"没法确认"处理，而不是当成确认通过。
    static func textBeforeCaret(_ count: Int) -> String? {
        guard count > 0, let caret = caretOffset(), caret >= count else { return nil }
        return readRange(location: caret - count, length: count)
    }

    /// 跨进程问辅助功能接口最多等这么久。
    ///
    /// 这些调用是**同步的跨进程 IPC**：目标 App 一忙或者干脆不响应，
    /// 调用方就一直等下去。默认超时是好几秒，而我们是在主线程上、
    /// 在每次要退格之前调它 —— 结果就是整个 App 冻住，浮层卡在"整理中"。
    ///
    /// 0.15 秒够正常的 App 回一次话；不回话的，就当"读不到"处理，
    /// 走没法核对那条路。**宁可核对不了，也不能把界面卡死。**
    private static let axTimeout: Float = 0.15

    private static func focusedElement() -> AXUIElement? {
        let system = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(system, axTimeout)
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            system, kAXFocusedUIElementAttribute as CFString, &focused
        ) == .success, let element = focused,
              CFGetTypeID(element) == AXUIElementGetTypeID()
        else { return nil }
        let focused = element as! AXUIElement
        AXUIElementSetMessagingTimeout(focused, axTimeout)
        return focused
    }

    static func copyToPasteboard(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    static var hasAccessibilityPermission: Bool {
        AXIsProcessTrusted()
    }

    /// 哪个 App 开着安全输入模式查不出来（系统不提供接口），
    /// 但至少能告诉用户是这件事挡住了。
    static var isSecureInputActive: Bool {
        IsSecureEventInputEnabled()
    }

    @discardableResult
    static func ensureAccessibilityPermission(prompt: Bool) -> Bool {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        return AXIsProcessTrustedWithOptions([key: prompt] as CFDictionary)
    }
}
