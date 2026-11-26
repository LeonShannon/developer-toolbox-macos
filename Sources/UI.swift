import AppKit

// MARK: - 按钮

/// 用闭包处理点击的按钮。
final class ActionButton: NSButton {
    enum Style { case normal, prominent, destructive, icon }

    var handler: () -> Void

    init(_ title: String, symbol: String? = nil, style: Style = .normal, handler: @escaping () -> Void = {}) {
        self.handler = handler
        super.init(frame: .zero)
        self.title = style == .icon ? "" : title
        bezelStyle = .rounded
        target = self
        action = #selector(performAction)
        if let symbol {
            image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)
            imagePosition = style == .icon ? .imageOnly : .imageLeading
            imageHugsTitle = true
        }
        switch style {
        case .normal: break
        case .prominent:
            bezelColor = .controlAccentColor
            keyEquivalent = ""
        case .destructive:
            hasDestructiveAction = true
            contentTintColor = .systemRed
        case .icon:
            toolTip = title
            setAccessibilityLabel(title)
        }
    }

    required init?(coder: NSCoder) { nil }

    @objc private func performAction() { handler() }
}

// MARK: - 卡片与图标

/// 圆角卡片容器，随系统外观自动更新背景与描边。
final class Card: NSStackView {
    var borderTint: NSColor? {
        didSet { needsDisplay = true }
    }
    override var wantsUpdateLayer: Bool { true }

    init(spacing: CGFloat = 12, insets: NSEdgeInsets = NSEdgeInsets(top: 16, left: 18, bottom: 16, right: 18)) {
        super.init(frame: .zero)
        orientation = .vertical
        alignment = .leading
        self.spacing = spacing
        edgeInsets = insets
        wantsLayer = true
    }

    required init?(coder: NSCoder) { nil }

    override func updateLayer() {
        guard let layer else { return }
        layer.cornerRadius = 12
        layer.cornerCurve = .continuous
        layer.borderWidth = borderTint == nil ? 1 : 1.5
        layer.backgroundColor = NSColor.controlBackgroundColor.cgColor
        layer.borderColor = (borderTint ?? NSColor.separatorColor.withAlphaComponent(0.25)).cgColor
    }
}

/// 带彩色底的 SF Symbol 图标，`solid` 为实心底白色图标（类似系统设置的侧栏）。
final class IconBadge: NSView {
    private let tint: NSColor
    private let solid: Bool
    private let radius: CGFloat
    override var wantsUpdateLayer: Bool { true }

    init(symbol: String, tint: NSColor, size: CGFloat, solid: Bool = false) {
        self.tint = tint
        self.solid = solid
        radius = size * 0.27
        super.init(frame: NSRect(x: 0, y: 0, width: size, height: size))
        wantsLayer = true
        let icon = NSImageView(image: NSImage(systemSymbolName: symbol, accessibilityDescription: nil) ?? NSImage())
        icon.symbolConfiguration = .init(pointSize: size * 0.5, weight: .semibold)
        icon.contentTintColor = solid ? .white : tint
        addSubview(icon)
        icon.translatesAutoresizingMaskIntoConstraints = false
        translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: size),
            heightAnchor.constraint(equalToConstant: size),
            icon.centerXAnchor.constraint(equalTo: centerXAnchor),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { nil }

    override func updateLayer() {
        layer?.cornerRadius = radius
        layer?.cornerCurve = .continuous
        layer?.backgroundColor = (solid ? tint : tint.withAlphaComponent(0.14)).cgColor
    }
}

/// 状态胶囊：空闲 / 运行中 / 成功 / 失败。
final class StatusPill: NSView {
    enum State { case idle, running, success, failure }

    private let spinner = NSProgressIndicator()
    private let icon = NSImageView()
    private let label = NSTextField(labelWithString: "")
    private var tint: NSColor = .secondaryLabelColor
    override var wantsUpdateLayer: Bool { true }

    var text: String { label.stringValue }

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        icon.symbolConfiguration = .init(pointSize: 11, weight: .bold)
        label.font = .systemFont(ofSize: 12, weight: .medium)
        label.lineBreakMode = .byTruncatingTail
        let row = NSStackView(views: [spinner, icon, label])
        row.spacing = 5
        row.edgeInsets = NSEdgeInsets(top: 3, left: 9, bottom: 3, right: 10)
        addSubview(row)
        row.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: leadingAnchor),
            row.trailingAnchor.constraint(equalTo: trailingAnchor),
            row.topAnchor.constraint(equalTo: topAnchor),
            row.bottomAnchor.constraint(equalTo: bottomAnchor),
            spinner.widthAnchor.constraint(equalToConstant: 14),
            spinner.heightAnchor.constraint(equalToConstant: 14),
        ])
        set(.idle, "空闲")
    }

    required init?(coder: NSCoder) { nil }

    func set(_ state: State, _ text: String) {
        label.stringValue = text
        let symbol: String?
        switch state {
        case .idle: tint = .secondaryLabelColor; symbol = "circle.fill"
        case .running: tint = .controlAccentColor; symbol = nil
        case .success: tint = .systemGreen; symbol = "checkmark.circle.fill"
        case .failure: tint = .systemRed; symbol = "xmark.circle.fill"
        }
        if state == .running { spinner.startAnimation(nil) } else { spinner.stopAnimation(nil) }
        spinner.isHidden = state != .running
        icon.isHidden = symbol == nil
        icon.image = symbol.flatMap { NSImage(systemSymbolName: $0, accessibilityDescription: nil) }
        if state == .idle { icon.symbolConfiguration = .init(pointSize: 7, weight: .bold) }
        else { icon.symbolConfiguration = .init(pointSize: 11, weight: .bold) }
        icon.contentTintColor = tint
        label.textColor = state == .idle ? .secondaryLabelColor : tint
        needsDisplay = true
    }

    override func updateLayer() {
        layer?.cornerRadius = bounds.height / 2
        layer?.backgroundColor = tint.withAlphaComponent(0.12).cgColor
    }

    override func layout() {
        super.layout()
        layer?.cornerRadius = bounds.height / 2
    }
}

// MARK: - 设备选择

/// 设备单选框组：平铺展示已连接设备，点击一次即可切换。
final class DevicePicker: NSView {
    private let allowsEmptySelection: Bool
    private let maxWidth: CGFloat
    private let stack = NSStackView()
    private let emptyLabel = NSTextField(labelWithString: "")
    private var items: [(device: Device, button: NSButton)] = []
    private var currentSelection: Device?

    var onChange: ((Device?) -> Void)?
    var selectedDevice: Device? { currentSelection }
    var devices: [Device] { items.map(\.device) }
    override var mouseDownCanMoveWindow: Bool { false }

    init(allowsEmptySelection: Bool = false, maxWidth: CGFloat = 460) {
        self.allowsEmptySelection = allowsEmptySelection
        self.maxWidth = maxWidth
        super.init(frame: .zero)
        setupUI()
        reload([], selected: nil, emptyTitle: "正在读取设备…")
    }

    required init?(coder: NSCoder) { nil }

    private func setupUI() {
        translatesAutoresizingMaskIntoConstraints = false
        setContentHuggingPriority(.required, for: .horizontal)
        setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.setContentHuggingPriority(.required, for: .horizontal)
        stack.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        emptyLabel.font = .systemFont(ofSize: 12)
        emptyLabel.textColor = .secondaryLabelColor
        emptyLabel.lineBreakMode = .byTruncatingTail
        emptyLabel.translatesAutoresizingMaskIntoConstraints = false

        addSubview(stack)
        addSubview(emptyLabel)

        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 24),
            widthAnchor.constraint(lessThanOrEqualToConstant: maxWidth),

            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),

            emptyLabel.leadingAnchor.constraint(equalTo: leadingAnchor),
            emptyLabel.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    /// 重建单选列表。`selected` 不在列表中时：允许空选则清空选中，否则自动选中第一台设备。
    func reload(_ devices: [Device], selected: Device?, emptyTitle: String) {
        for entry in items {
            entry.button.removeFromSuperview()
        }
        items.removeAll()

        guard !devices.isEmpty else {
            currentSelection = nil
            stack.isHidden = true
            emptyLabel.isHidden = false
            emptyLabel.stringValue = emptyTitle
            invalidateIntrinsicContentSize()
            return
        }

        emptyLabel.isHidden = true
        stack.isHidden = false

        let labelCounts = Dictionary(devices.map { ($0.label, 1) }, uniquingKeysWith: +)
        for (index, device) in devices.enumerated() {
            let duplicate = (labelCounts[device.label] ?? 0) > 1
            let title = duplicate ? "\(device.label) (\(device.serial.suffix(4)))" : device.label
            let button = NSButton(radioButtonWithTitle: title, target: self, action: #selector(radioClicked(_:)))
            button.tag = index
            button.font = .systemFont(ofSize: 12.5, weight: .regular)
            button.controlSize = .small
            button.lineBreakMode = .byTruncatingMiddle
            button.toolTip = "\(device.platform.rawValue) · \(device.label) (\(device.serial))"
            button.setContentHuggingPriority(.required, for: .horizontal)
            button.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            stack.addArrangedSubview(button)
            items.append((device, button))
        }

        select(selected)
        invalidateIntrinsicContentSize()
        needsLayout = true
    }

    func select(_ device: Device?) {
        if let device, let index = items.firstIndex(where: { $0.device.identifies(device) }) {
            setSelectedIndex(index)
        } else if allowsEmptySelection || items.isEmpty {
            setSelectedIndex(nil)
        } else {
            setSelectedIndex(0)
        }
    }

    func buttonFrameForSelfTest(at index: Int) -> NSRect? {
        guard index >= 0, index < items.count else { return nil }
        let button = items[index].button
        return button.convert(button.bounds, to: nil)
    }

    func radioButtonForSelfTest(at index: Int) -> NSButton? {
        guard index >= 0, index < items.count else { return nil }
        return items[index].button
    }

    override var intrinsicContentSize: NSSize {
        if items.isEmpty {
            let textSize = emptyLabel.intrinsicContentSize
            return NSSize(width: min(maxWidth, max(80, textSize.width)), height: 24)
        }
        return NSSize(width: min(maxWidth, max(80, stack.fittingSize.width)), height: 24)
    }

    private func setSelectedIndex(_ index: Int?) {
        for (idx, entry) in items.enumerated() {
            entry.button.state = (idx == index) ? .on : .off
        }
        currentSelection = index.map { items[$0].device }
    }

    @objc private func radioClicked(_ sender: NSButton) {
        let index = sender.tag
        guard index >= 0, index < items.count else { return }
        setSelectedIndex(index)
        onChange?(currentSelection)
    }
}

// MARK: - 布局辅助

final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

enum UI {
    static func label(_ text: String, size: CGFloat = 13, weight: NSFont.Weight = .regular,
                      color: NSColor = .labelColor) -> NSTextField {
        let field = NSTextField(labelWithString: text)
        field.font = .systemFont(ofSize: size, weight: weight)
        field.textColor = color
        return field
    }

    /// 可换行的说明文字。
    static func note(_ text: String, size: CGFloat = 12) -> NSTextField {
        let field = NSTextField(wrappingLabelWithString: text)
        field.font = .systemFont(ofSize: size)
        field.textColor = .secondaryLabelColor
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return field
    }

    static func vstack(_ views: [NSView] = [], spacing: CGFloat = 8,
                       alignment: NSLayoutConstraint.Attribute = .leading) -> NSStackView {
        let stack = NSStackView(views: views)
        stack.orientation = .vertical
        stack.alignment = alignment
        stack.spacing = spacing
        return stack
    }

    static func hstack(_ views: [NSView] = [], spacing: CGFloat = 8) -> NSStackView {
        let stack = NSStackView(views: views)
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = spacing
        return stack
    }

    static func spacer() -> NSView {
        let view = NSView()
        view.setContentHuggingPriority(.init(1), for: .horizontal)
        view.setContentCompressionResistancePriority(.init(1), for: .horizontal)
        return view
    }

    /// 卡片标题行：图标 + 标题 + 说明。
    static func cardHeader(symbol: String, tint: NSColor, title: String, detail: String) -> NSStackView {
        let labels = vstack([label(title, size: 15, weight: .semibold), note(detail)], spacing: 3)
        let row = hstack([IconBadge(symbol: symbol, tint: tint, size: 38), labels], spacing: 12)
        row.alignment = .centerY
        return row
    }

    static func separator() -> NSBox {
        let box = NSBox()
        box.boxType = .separator
        return box
    }

    static func monospacedTextView(fontSize: CGFloat = 12) -> (NSScrollView, NSTextView) {
        let text = NSTextView()
        text.isEditable = false
        text.isRichText = false
        text.font = .monospacedSystemFont(ofSize: fontSize, weight: .regular)
        text.textContainerInset = NSSize(width: 10, height: 8)
        text.isVerticallyResizable = true
        text.autoresizingMask = [.width]
        text.textContainer?.widthTracksTextView = true
        text.drawsBackground = true
        text.backgroundColor = .textBackgroundColor
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        scroll.documentView = text
        scroll.wantsLayer = true
        scroll.layer?.cornerRadius = 8
        scroll.layer?.cornerCurve = .continuous
        scroll.layer?.masksToBounds = true
        return (scroll, text)
    }
}

extension NSStackView {
    /// 添加子视图并使其撑满栈的宽度（垂直栈）。
    func addFullWidth(_ view: NSView) {
        addArrangedSubview(view)
        view.leadingAnchor.constraint(equalTo: leadingAnchor, constant: edgeInsets.left).isActive = true
        view.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -edgeInsets.right).isActive = true
    }
}
