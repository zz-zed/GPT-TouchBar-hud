import AppKit

/// A native panel embedded in the existing top-tab settings window.
final class APICostPreferencesView: NSView {
    var onValidate: ((String, @escaping (Bool) -> Void) -> Void)?
    var onCancelValidation: (() -> Void)?
    var onEnabled: ((Bool) -> Void)?
    var onRefresh: (() -> Void)?
    var onDisconnect: (() -> Void)?
    private var state = APICostViewState()
    private var editing = false
    private let enabled = NSButton(checkboxWithTitle: "显示 API 消费", target: nil, action: nil)
    private let connection = NSTextField(wrappingLabelWithString: "")
    private let amount = NSTextField(labelWithString: "—")
    private let timing = NSTextField(labelWithString: "")
    private let status = NSTextField(wrappingLabelWithString: "")
    private let input = NSSecureTextField()
    private let inputLabel = NSTextField(labelWithString: "Admin API key")
    private let verify = NSButton(title: "验证并启用", target: nil, action: nil)
    private let cancel = NSButton(title: "取消", target: nil, action: nil)
    private let refresh = NSButton(title: "刷新消费", target: nil, action: nil)
    private let replace = NSButton(title: "更换密钥…", target: nil, action: nil)
    private let disconnect = NSButton(title: "断开连接…", target: nil, action: nil)
    private let credentialNote = NSTextField(wrappingLabelWithString: "仅保存在本机钥匙串，不写入日志。普通模型密钥可能没有费用查询权限。")
    private var editor: NSStackView!
    private var controls: NSStackView!
    private let detail = NSTextField(wrappingLabelWithString: "每 15 分钟获取一次。按 UTC 自然月统计当前接入对应的全部 API 费用，可能包含多个项目和 API Key。费用统计可能存在延迟。")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        let intro = NSTextField(wrappingLabelWithString: "在菜单栏和刘海用量页查看本月 API 已消费金额。")
        amount.font = .monospacedDigitSystemFont(ofSize: 20, weight: .semibold)
        for label in [connection, timing, status, credentialNote, detail] {
            label.font = .systemFont(ofSize: 11); label.textColor = .secondaryLabelColor
        }
        input.placeholderString = "输入管理员密钥"
        input.setAccessibilityLabel("Admin API key")
        input.setAccessibilityIdentifier("settings.apiCosts.key")
        enabled.setAccessibilityIdentifier("settings.apiCosts.enabled")
        verify.setAccessibilityIdentifier("settings.apiCosts.verify")
        cancel.setAccessibilityIdentifier("settings.apiCosts.cancel")
        refresh.setAccessibilityIdentifier("settings.apiCosts.refresh")
        replace.setAccessibilityIdentifier("settings.apiCosts.replace")
        disconnect.setAccessibilityIdentifier("settings.apiCosts.disconnect")
        status.setAccessibilityIdentifier("settings.apiCosts.status")
        enabled.target = self; enabled.action = #selector(toggle)
        verify.target = self; verify.action = #selector(validate)
        cancel.target = self; cancel.action = #selector(cancelEdit)
        refresh.target = self; refresh.action = #selector(refreshNow)
        replace.target = self; replace.action = #selector(replaceKey)
        disconnect.target = self; disconnect.action = #selector(disconnectKey)
        for button in [verify, cancel, refresh, replace, disconnect] { button.bezelStyle = .rounded }
        let editorActions = NSStackView(views: [verify, cancel]); editorActions.spacing = 8
        editor = NSStackView(views: [inputLabel, input, credentialNote, editorActions])
        editor.orientation = .vertical; editor.alignment = .leading; editor.spacing = 8
        controls = NSStackView(views: [refresh, replace, disconnect]); controls.spacing = 8
        let help = NSButton(title: "打开管理员密钥页面 ↗", target: self, action: #selector(openHelp))
        help.bezelStyle = .rounded; help.setAccessibilityIdentifier("settings.apiCosts.help")
        let stack = NSStackView(views: [intro, enabled, connection, amount, timing, editor, controls, status, detail, help])
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 10
        addSubview(stack); stack.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor), stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor), stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            editor.widthAnchor.constraint(equalTo: stack.widthAnchor), input.widthAnchor.constraint(equalTo: editor.widthAnchor),
            intro.widthAnchor.constraint(equalTo: stack.widthAnchor), credentialNote.widthAnchor.constraint(equalTo: stack.widthAnchor),
            status.widthAnchor.constraint(equalTo: stack.widthAnchor), detail.widthAnchor.constraint(equalTo: stack.widthAnchor)
        ])
        update(state)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    func update(_ state: APICostViewState) {
        self.state = state
        let showEditor = !state.configured || editing
        enabled.isHidden = !state.configured
        enabled.state = state.enabled ? .on : .off
        connection.isHidden = !state.configured || showEditor
        connection.stringValue = state.error?.requiresRepair == true ? "接入需要修复" : "已连接 · 密钥保存在本机钥匙串"
        amount.isHidden = !state.configured || showEditor
        timing.isHidden = amount.isHidden
        amount.stringValue = "本月 API 消费  " + state.amountText(language: .chinese)
        timing.stringValue = state.enabled ? state.detail(language: .chinese) : "已暂停显示与自动刷新"
        editor.isHidden = !showEditor; controls.isHidden = showEditor
        cancel.isHidden = !state.configured && !state.validating
        input.isEnabled = !state.validating
        verify.isEnabled = !state.validating
        verify.title = state.validating ? "正在验证…" : (state.configured ? "验证并替换" : "验证并启用")
        refresh.isEnabled = state.canRefresh
        refresh.title = state.refreshing ? "正在刷新…" : "刷新消费"
        let error = showEditor ? state.validationError : (state.validationError ?? state.error)
        status.stringValue = error?.message(language: .chinese) ?? (state.validating ? "正在验证费用查询权限…" : (state.configured && !showEditor && state.enabled ? state.status(language: .chinese) : ""))
        if !showEditor, state.enabled, error == nil, !state.refreshing,
           let diagnostic = state.snapshot?.emptyResponseDiagnostic {
            status.stringValue = diagnostic
        }
        status.isHidden = status.stringValue.isEmpty
        status.textColor = error != nil ? .systemRed : .secondaryLabelColor
        credentialNote.stringValue = state.configured
            ? "验证成功后替换本机钥匙串中的密钥；验证失败保留原配置。"
            : "仅保存在本机钥匙串，不写入日志。普通模型密钥可能没有费用查询权限。"
    }
    /// Closing the window cancels candidate validation and removes input from the view.
    func clearEditor() { onCancelValidation?(); input.stringValue = ""; editing = false; update(state) }
    @objc private func toggle() { let value = enabled.state == .on; clearEditor(); onEnabled?(value) }
    @objc private func validate() {
        let candidate = input.stringValue
        guard !candidate.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { input.window?.makeFirstResponder(input); return }
        onValidate?(candidate) { [weak self] success in
            guard let self else { return }
            self.input.stringValue = ""
            if success { self.editing = false }
            self.update(self.state)
        }
    }
    @objc private func cancelEdit() { clearEditor() }
    @objc private func replaceKey() { editing = true; input.stringValue = ""; update(state); window?.makeFirstResponder(input) }
    @objc private func refreshNow() { onRefresh?() }
    @objc private func disconnectKey() {
        guard let window else { return }
        let alert = NSAlert()
        alert.messageText = "断开 API 消费连接？"
        alert.informativeText = "移除本机保存的接入密钥并清除消费显示。Codex 额度与 Token 信息不受影响。"
        alert.addButton(withTitle: "取消"); alert.addButton(withTitle: "断开连接")
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertSecondButtonReturn else { return }
            self?.clearEditor(); self?.onDisconnect?()
        }
    }
    @objc private func openHelp() {
        NSWorkspace.shared.open(URL(string: "https://platform.openai.com/settings/organization/admin-keys")!)
    }
}
