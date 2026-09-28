import AppKit

final class ConnectionDiagnosticsWindowController: NSWindowController, NSWindowDelegate {
    private let runner: ConnectionDiagnosticsRunner
    private let status = NSTextField(wrappingLabelWithString: "尚未检查")
    private let review = NSTextView()
    private let checkButton = NSButton(title: "重新检查", target: nil, action: nil)
    private let copyButton = NSButton(title: "复制诊断信息", target: nil, action: nil)

    init(runner: ConnectionDiagnosticsRunner = ConnectionDiagnosticsRunner()) {
        self.runner = runner
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 740, height: 580),
                              styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = "连接检查与诊断"
        window.minSize = NSSize(width: 600, height: 440)
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self
        configure()
        runner.onUpdate = { [weak self] report in self?.update(report) }
        window.center()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func showAndCheck() {
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        startCheck()
    }

    func startCheck() { runner.startCheck() }

    func windowWillClose(_ notification: Notification) { runner.cancel() }

    private func configure() {
        guard let content = window?.contentView else { return }
        let explanation = NSTextField(wrappingLabelWithString:
            "按需检查宿主、登录状态和账号接口。报告仅含环境与检查结果；复制内容与下方预览完全一致。检查结束或关闭窗口后断开本次连接。")
        explanation.font = .systemFont(ofSize: 12)
        explanation.textColor = .secondaryLabelColor
        status.font = .systemFont(ofSize: 14, weight: .medium)
        checkButton.target = self
        checkButton.action = #selector(checkAgain)
        copyButton.target = self
        copyButton.action = #selector(copyReport)
        copyButton.isEnabled = false
        let buttons = NSStackView(views: [checkButton, copyButton])
        buttons.orientation = .horizontal
        buttons.spacing = 12
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        review.isEditable = false
        review.isSelectable = true
        review.isRichText = false
        review.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        review.textContainerInset = NSSize(width: 10, height: 10)
        review.isVerticallyResizable = true
        review.isHorizontallyResizable = false
        review.autoresizingMask = [.width]
        review.textContainer?.widthTracksTextView = true
        review.string = "点击重新检查以生成可复制的诊断报告。"
        scroll.documentView = review
        let stack = NSStackView(views: [status, explanation, scroll, buttons])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 14
        content.addSubview(stack)
        stack.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 20),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -20),
            explanation.widthAnchor.constraint(equalTo: stack.widthAnchor),
            scroll.widthAnchor.constraint(equalTo: stack.widthAnchor),
            scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 230)
        ])
    }

    private func update(_ report: ConnectionDiagnosticsReport) {
        status.stringValue = report.summary
        review.string = report.text
        checkButton.isEnabled = !report.isRunning
        copyButton.isEnabled = !report.isRunning
    }

    @objc private func checkAgain() { startCheck() }

    @objc private func copyReport() {
        guard runner.report?.isRunning == false else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(review.string, forType: .string)
        status.stringValue = "诊断信息已复制"
    }
}
