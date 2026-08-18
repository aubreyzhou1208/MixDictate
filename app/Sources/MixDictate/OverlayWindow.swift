import AppKit

/// 录音时显示实时转写结果的浮层。
///
/// 关键约束：这个窗口**绝对不能抢焦点**。用 .nonactivatingPanel + 手动
/// orderFrontRegardless()，一旦焦点跑到浮层上，"插入到当前光标处"就废了 ——
/// 粘贴会粘到一个不存在的输入框里。
@MainActor
final class OverlayWindow {
    /// 两种形态解决的是两个不同的问题。
    ///
    /// 实时写入时文字已经在光标处了，浮层再显示一遍纯属噪音 —— 但完全不显示
    /// 又会让人不确定它到底在不在工作。所以给一个小指示器：只回答
    /// "它在干活吗"，不重复内容。
    ///
    /// 非实时时文字要松手才出现，那段时间里浮层是唯一的反馈，得显示全文。
    enum Style {
        case fullText
        case compact
    }

    private var style: Style = .fullText
    private var panel: NSPanel?
    private var label: NSTextField?
    private var hideWorkItem: DispatchWorkItem?
    private var pulseTimer: Timer?
    private var pulseBright = true
    private var currentStatus = ""

    private var width: CGFloat { style == .compact ? 230 : 560 }
    private let horizontalPadding: CGFloat = 20
    private let verticalPadding: CGFloat = 16

    // MARK: - 显示

    func show(style: Style, status: String) {
        hideWorkItem?.cancel()
        hideWorkItem = nil

        self.style = style
        let panel = existingPanel()
        applyStatus(status)
        layout()
        startPulse()

        // 不用 makeKeyAndOrderFront —— 那会抢焦点
        panel.orderFrontRegardless()
    }

    /// 更新状态文字。两种形态都生效。
    func setStatus(_ status: String) {
        guard panel != nil else { return }
        applyStatus(status)
        layout()
    }

    /// 圆点做呼吸效果。静态的点看不出程序有没有卡住 ——
    /// 会动的点一眼就知道它还活着，这正是这个指示器存在的意义。
    private func startPulse() {
        guard style == .compact else { return }
        pulseTimer?.invalidate()
        pulseTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in
                self.pulseBright.toggle()
                self.applyStatus(self.currentStatus)
            }
        }
    }

    private func stopPulse() {
        pulseTimer?.invalidate()
        pulseTimer = nil
        pulseBright = true
    }

    private func applyStatus(_ status: String) {
        guard let label else { return }
        currentStatus = status

        guard style == .compact else {
            label.stringValue = status
            label.textColor = .secondaryLabelColor
            return
        }

        // 小指示器：一个圆点 + 状态。圆点用彩色让人一眼看到"它在动"，
        // 文字保持次要色，不喧宾夺主。
        let text = NSMutableAttributedString(
            string: "● ",
            attributes: [
                .foregroundColor: pulseBright
                    ? NSColor.systemRed
                    : NSColor.systemRed.withAlphaComponent(0.25)
            ]
        )
        text.append(
            NSAttributedString(
                string: status,
                attributes: [.foregroundColor: NSColor.labelColor]
            )
        )
        label.attributedStringValue = text
    }

    func update(_ text: String, isFinal: Bool) {
        guard panel != nil else { return }

        // 小指示器不显示转写内容 —— 那正是它存在的意义
        guard style == .fullText else { return }

        label?.stringValue = text.isEmpty ? "…" : Self.trimmedForDisplay(text)
        label?.textColor = isFinal ? .labelColor : .secondaryLabelColor
        layout()
    }

    /// 只显示末尾一段。
    ///
    /// 之前是原样显示：说得越久面板越高，最后高过屏幕，看起来就像
    /// "超过一定字数就不更新了"。浮层的用途是看最新进展，不是回读全文。
    private static func trimmedForDisplay(_ text: String) -> String {
        let limit = 140
        guard text.count > limit else { return text }
        return "…" + String(text.suffix(limit))
    }

    func hide(after delay: TimeInterval = 0) {
        hideWorkItem?.cancel()

        stopPulse()

        guard delay > 0 else {
            panel?.orderOut(nil)
            return
        }

        // 松手后让最终结果在屏幕上停一下，用户才看得清改成了什么
        let work = DispatchWorkItem { [weak self] in
            self?.panel?.orderOut(nil)
        }
        hideWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    // MARK: - 构建

    private func existingPanel() -> NSPanel {
        if let panel { return panel }

        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: width, height: 80),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .statusBar
        panel.ignoresMouseEvents = true
        // 切到别的桌面 / 全屏 App 时浮层要跟过去
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]

        let effect = NSVisualEffectView()
        effect.material = .hudWindow
        effect.blendingMode = .behindWindow
        effect.state = .active
        // 圆角必须用 maskImage 而不是 layer.cornerRadius。
        // NSVisualEffectView 的材质是系统在图层之外合成的，cornerRadius +
        // masksToBounds 裁不干净，四角会露出一圈没被裁掉的白边。
        effect.maskImage = Self.roundedMask(radius: 14)

        let label = NSTextField(wrappingLabelWithString: "")
        label.font = .systemFont(ofSize: 15)
        label.alignment = .center
        label.isEditable = false
        label.isSelectable = false
        label.backgroundColor = .clear
        label.isBezeled = false

        effect.addSubview(label)
        panel.contentView = effect

        self.panel = panel
        self.label = label
        return panel
    }

    /// 可拉伸的圆角遮罩。capInsets 让四角保持原样、只拉伸中间，
    /// 这样同一张图能适配任意尺寸的浮层。
    private static func roundedMask(radius: CGFloat) -> NSImage {
        let diameter = radius * 2 + 1
        let image = NSImage(
            size: NSSize(width: diameter, height: diameter),
            flipped: false
        ) { rect in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
            return true
        }
        image.capInsets = NSEdgeInsets(
            top: radius, left: radius, bottom: radius, right: radius
        )
        image.resizingMode = .stretch
        return image
    }

    private func layout() {
        guard let panel, let label, let screen = NSScreen.main else { return }

        let textWidth = width - horizontalPadding * 2
        // 上限保证面板不会长到顶出屏幕
        let measured = label.sizeThatFits(
            NSSize(width: textWidth, height: .greatestFiniteMagnitude)
        ).height
        let textHeight = min(max(22, measured), 120)
        let panelHeight = textHeight + verticalPadding * 2

        let visible = screen.visibleFrame
        // 抬得比 Dock 高一截。放太低会被 Dock 或者别的 App 的底部工具栏
        // 挡住，用户就会以为"根本没显示"。
        let origin = NSPoint(
            x: visible.midX - width / 2,
            y: visible.minY + 160
        )

        panel.setFrame(
            NSRect(origin: origin, size: NSSize(width: width, height: panelHeight)),
            display: true
        )
        label.frame = NSRect(
            x: horizontalPadding,
            y: verticalPadding,
            width: textWidth,
            height: textHeight
        )
    }
}
