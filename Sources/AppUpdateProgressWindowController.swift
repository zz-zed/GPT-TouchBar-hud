import AppKit

private final class AppUpdateProgressWindow: NSWindow {
    var onHide: (() -> Void)?
    override func cancelOperation(_ sender: Any?) { onHide?() }
}

final class AppUpdateProgressWindowController: NSWindowController, NSWindowDelegate {
    var onCancel: (() -> Void)?
    var onRetry: (() -> Void)?
    var onOpenApplication: (() -> Void)?
    var onRecovery: (() -> Void)?
    var onHide: (() -> Void)?
    var ownerAvailable = true {
        didSet { if oldValue != ownerAvailable, let progress { update(progress, force: true) } }
    }
    private let heading = NSTextField(labelWithString: "正在准备下载")
    private let version = NSTextField(labelWithString: "")
    private let step = NSTextField(labelWithString: "")
    private let percentage = NSTextField(labelWithString: "")
    private let detail = NSTextField(wrappingLabelWithString: "")
    private let speed = NSTextField(labelWithString: "")
    private let hint = NSTextField(wrappingLabelWithString: "")
    private let indicator = NSProgressIndicator()
    private let secondary = NSButton(title: "取消下载", target: nil, action: nil)
    private let primary = NSButton(title: "后台继续", target: nil, action: nil)
    private var stages: [NSTextField] = []
    private var progress: AppUpdateProgress?

    init(sourceVersion: String, targetVersion: String) {
        let window = AppUpdateProgressWindow(contentRect: NSRect(x: 0, y: 0, width: 480, height: 334),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "软件更新 · GPT TouchBar HUD"
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self
        window.onHide = { [weak self] in self?.hide() }
        window.center()
        version.stringValue = "GPT TouchBar HUD · \(sourceVersion) → \(targetVersion)"
        configure()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func configure() {
        guard let content = window?.contentView else { return }
        heading.font = .systemFont(ofSize: 20, weight: .semibold)
        version.font = .systemFont(ofSize: 12); version.textColor = .secondaryLabelColor
        step.font = .systemFont(ofSize: 14, weight: .semibold)
        percentage.font = .monospacedDigitSystemFont(ofSize: 21, weight: .semibold)
        detail.font = .systemFont(ofSize: 12); detail.textColor = .secondaryLabelColor
        speed.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular); speed.textColor = .secondaryLabelColor
        hint.font = .systemFont(ofSize: 12); hint.textColor = .secondaryLabelColor
        hint.setContentCompressionResistancePriority(.required, for: .vertical)
        indicator.style = .bar; indicator.minValue = 0; indicator.maxValue = 1
        indicator.setAccessibilityLabel("更新进度")
        let names = ["下载", "校验", "安装", "重启"]
        stages = names.enumerated().map { index, name in
            let field = NSTextField(labelWithString: "\(index + 1)  \(name)")
            field.font = .systemFont(ofSize: 12)
            return field
        }
        let stagesRow = NSStackView(views: stages)
        stagesRow.orientation = .horizontal; stagesRow.distribution = .fillEqually
        let statusRow = NSStackView(views: [step, percentage])
        statusRow.orientation = .horizontal; statusRow.distribution = .fill
        step.setContentHuggingPriority(.defaultLow, for: .horizontal)
        percentage.setContentHuggingPriority(.required, for: .horizontal)
        let detailRow = NSStackView(views: [detail, speed])
        detailRow.orientation = .horizontal; detailRow.alignment = .top
        detail.setContentHuggingPriority(.defaultLow, for: .horizontal)
        speed.setContentHuggingPriority(.required, for: .horizontal)
        primary.bezelStyle = .rounded; secondary.bezelStyle = .rounded
        primary.target = self; primary.action = #selector(primaryClicked)
        secondary.target = self; secondary.action = #selector(secondaryClicked)
        primary.keyEquivalent = "\r"
        secondary.setAccessibilityIdentifier("update-progress.secondary")
        primary.setAccessibilityIdentifier("update-progress.primary")
        let spacer = NSView()
        let actions = NSStackView(views: [spacer, secondary, primary])
        actions.orientation = .horizontal; actions.spacing = 10
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let stack = NSStackView(views: [heading, version, stagesRow, statusRow, indicator, detailRow, hint, actions])
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 12
        stack.setCustomSpacing(3, after: heading)
        stack.setCustomSpacing(22, after: version)
        stack.setCustomSpacing(18, after: stagesRow)
        stack.setCustomSpacing(4, after: indicator)
        stack.setCustomSpacing(18, after: detailRow)
        stack.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 28),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -28),
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 26),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: content.bottomAnchor, constant: -24)
        ])
        for view in [stagesRow, statusRow, indicator, detailRow, hint, actions] {
            view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
    }

    func update(_ value: AppUpdateProgress, force: Bool = false) {
        guard force || progress != value else { return }
        progress = value
        heading.stringValue = value.heading
        step.stringValue = value.phase == .succeeded ? "已更新至 " + version.stringValue.components(separatedBy: " → ").last! : value.step.title
        if value.phase == .failed || value.phase == .launchUnconfirmed { step.stringValue = "更新需要处理" }
        if value.phase == .canceled { step.stringValue = "下载已停止" }
        step.textColor = [.failed, .launchUnconfirmed].contains(value.phase) ? .systemRed : .labelColor
        let fraction = value.downloadFraction
        percentage.isHidden = fraction == nil
        percentage.stringValue = fraction.map { "\(Int($0 * 100))%" } ?? ""
        indicator.isHidden = !value.isActive && value.phase != .succeeded
        indicator.isIndeterminate = fraction == nil && value.phase != .succeeded
        if indicator.isIndeterminate { indicator.startAnimation(nil) }
        else { indicator.stopAnimation(nil); indicator.doubleValue = fraction ?? 1 }
        indicator.setAccessibilityLabel(value.phase == .downloading ? "安装包下载进度" : value.step.title)
        indicator.setAccessibilityValueDescription(fraction.map { "下载 \(Int($0 * 100))%，下载完成后继续校验和安装" } ?? value.step.title)
        detail.stringValue = value.detail
        speed.stringValue = value.bytesPerSecond.map { ByteCountFormatter.string(fromByteCount: Int64(max(0, $0)), countStyle: .file) + "/s" } ?? ""
        speed.isHidden = value.phase != .downloading || value.bytesPerSecond == nil
        if value.phase == .failed {
            switch value.recovery {
            case .untouched: hint.stringValue = "原应用尚未替换，可稍后再更新。"
            case .restored: hint.stringValue = "旧版已恢复并完成启动，可稍后再更新。"
            case .backupRetained: hint.stringValue = "旧版备份已保留，可查看恢复说明。"
            case .needsRecovery: hint.stringValue = "请查看本次更新目录中的日志与应用，确认安装状态。"
            }
        } else {
            hint.stringValue = value.canCancel ? "下载期间可以继续使用。收起窗口后，更新在后台继续。" :
                value.isActive ? "当前阶段无法取消。收起窗口后，更新在后台继续。" : value.phase == .succeeded ? "新版已启动，你可以继续使用本工具。" : "可稍后从菜单栏查看更新或继续处理。"
        }
        for (index, field) in stages.enumerated() {
            field.stringValue = (index < value.step.stage ? "✓" : "\(index + 1)") + "  " + ["下载", "校验", "安装", "重启"][index]
            field.textColor = index == value.step.stage ? .systemBlue : index < value.step.stage ? .systemGreen : .secondaryLabelColor
            field.setAccessibilityLabel(field.stringValue + (index == value.step.stage ? "，当前阶段" : ""))
        }
        secondary.isHidden = !(value.canCancel || value.phase == .failed || value.phase == .launchUnconfirmed)
        secondary.title = value.canCancel ? "取消下载" : value.recovery == .untouched ? "稍后" : "查看恢复说明"
        primary.title = value.canRetry && ownerAvailable ? "重新下载" :
            value.phase == .launchUnconfirmed || (value.phase == .failed && !ownerAvailable) ? "打开应用" : value.isActive ? "后台继续" : "完成"
        window?.contentView?.layoutSubtreeIfNeeded()
        if let content = window?.contentView, let stack = content.subviews.first {
            let requiredHeight = stack.fittingSize.height + 50
            if abs(content.frame.height - requiredHeight) > 2 {
                window?.setContentSize(NSSize(width: 480, height: max(334, requiredHeight)))
            }
        }
    }

    func present(userInitiated: Bool) {
        window?.makeKeyAndOrderFront(nil)
        if userInitiated { NSApp.activate(ignoringOtherApps: true) }
    }
    func hide() { window?.orderOut(nil); onHide?() }
    func windowShouldClose(_ sender: NSWindow) -> Bool { hide(); return false }
    @objc private func primaryClicked() {
        if progress?.canRetry == true && ownerAvailable { onRetry?() }
        else if progress?.phase == .launchUnconfirmed || (progress?.phase == .failed && !ownerAvailable) { onOpenApplication?() }
        else { hide() }
    }
    @objc private func secondaryClicked() {
        if progress?.canCancel == true { onCancel?() }
        else if progress?.recovery != .untouched { onRecovery?() }
        else { hide() }
    }
}
