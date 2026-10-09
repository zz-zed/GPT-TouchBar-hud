import AppKit

final class ConnectionDiagnosticsWindowController: NSWindowController, NSWindowDelegate, NSTextFieldDelegate {
    private let runner: ConnectionDiagnosticsRunner
    private let recorder: DiagnosticRecorder
    private let exporter: DiagnosticExportCoordinator
    private let defaults: UserDefaults
    private let environment: () -> DiagnosticEnvironmentSnapshot
    private let status = NSTextField(wrappingLabelWithString: "尚未检查；打开窗口不会建立诊断连接")
    private let recordingStatus = NSTextField(wrappingLabelWithString: "")
    private let review = NSTextView()
    private let checkButton = NSButton(title: "检查当前状态", target: nil, action: nil)
    private let copyButton = NSButton(title: "复制诊断信息", target: nil, action: nil)
    private let previewButton = NSButton(title: "生成导出预览", target: nil, action: nil)
    private let saveButton = NSButton(title: "保存 ZIP…", target: nil, action: nil)
    private let cancelButton = NSButton(title: "取消", target: nil, action: nil)
    private let recordingToggle = NSButton(checkboxWithTitle: "基础记录仅保存在本机", target: nil, action: nil)
    private let clearButton = NSButton(title: "清除本地记录", target: nil, action: nil)
    private let retryRecordingButton = NSButton(title: "重试记录设置", target: nil, action: nil)
    private let ranges = NSPopUpButton()
    private let files = NSPopUpButton()
    private let descriptionInput = NSTextField()
    private let problemTimeToggle = NSButton(checkboxWithTitle: "附上发生时间", target: nil, action: nil)
    private let problemTime = NSDatePicker()
    private var snapshot: DiagnosticExportSnapshot?
    private var revision: UInt64 = 0
    private var exporting = false
    private var recordingChangePending = false
    private var failedRecordingValue: Bool?

    init(runner: ConnectionDiagnosticsRunner = ConnectionDiagnosticsRunner(),
         recorder: DiagnosticRecorder = .shared, exporter: DiagnosticExportCoordinator = .shared,
         defaults: UserDefaults = .standard,
         environment: @escaping () -> DiagnosticEnvironmentSnapshot = DiagnosticEnvironmentSnapshot.current) {
        self.runner = runner
        self.recorder = recorder
        self.exporter = exporter
        self.defaults = defaults
        self.environment = environment
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 780, height: 740),
                              styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = "诊断与反馈"
        window.minSize = NSSize(width: 680, height: 670)
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self
        configure()
        runner.onUpdate = { [weak self] report in self?.update(report) }
        window.center()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// Kept for existing settings callers; checking now requires the explicit button.
    func showAndCheck() {
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        if snapshot == nil { status.stringValue = runner.report?.summary ?? "尚未检查；打开窗口不会建立诊断连接" }
        updateRecordingStatus()
        loadOverview()
    }

    func startCheck() {
        invalidatePreview()
        runner.startCheck()
    }

    func windowWillClose(_ notification: Notification) {
        revision &+= 1
        exporter.invalidate()
        snapshot = nil
        runner.cancel()
        exporting = false
        refreshButtons()
        files.removeAllItems()
        review.string = "窗口已关闭，旧预览已失效；重新打开后可生成新的导出预览。"
    }

    private func configure() {
        guard let content = window?.contentView else { return }
        let explanation = NSTextField(wrappingLabelWithString:
            "基础记录最长保存 72 小时、最多 10 MiB。导出只读取已有事件和检查结果；检查当前状态才会建立短时连接。问题说明只进入本次快照，请勿填写凭据或对话内容。修改输入后需重新生成预览。")
        explanation.font = .systemFont(ofSize: 12)
        explanation.textColor = .secondaryLabelColor
        status.font = .systemFont(ofSize: 14, weight: .medium)
        recordingStatus.font = .systemFont(ofSize: 12)
        recordingStatus.textColor = .secondaryLabelColor
        for (button, action) in [(checkButton, #selector(checkAgain)), (copyButton, #selector(copyReport)),
                                 (previewButton, #selector(generatePreview)), (saveButton, #selector(saveZIP)),
                                 (cancelButton, #selector(cancelDiagnostics)), (clearButton, #selector(clearRecords)),
                                 (recordingToggle, #selector(changeRecording))] {
            button.target = self
            button.action = action
        }
        recordingToggle.state = recorder.isEnabled ? .on : .off
        retryRecordingButton.target = self
        retryRecordingButton.action = #selector(retryRecordingChange)
        retryRecordingButton.isHidden = true
        ranges.addItems(withTitles: DiagnosticExportRange.allCases.map(\.title))
        ranges.selectItem(at: 0)
        ranges.target = self
        ranges.action = #selector(exportInputsChanged)
        files.target = self
        files.action = #selector(selectFile)
        descriptionInput.placeholderString = "问题说明（可选，仅进入本次预览和 ZIP，最多 4096 字符）"
        descriptionInput.delegate = self
        problemTime.datePickerStyle = .textFieldAndStepper
        problemTime.datePickerElements = [.yearMonthDay, .hourMinuteSecond]
        problemTime.dateValue = Date()
        problemTime.target = self
        problemTime.action = #selector(exportInputsChanged)
        problemTime.isEnabled = false
        problemTimeToggle.target = self
        problemTimeToggle.action = #selector(changeProblemTime)
        let recording = row([recordingToggle, clearButton, retryRecordingButton])
        let range = row([NSTextField(labelWithString: "导出范围"), ranges,
                         NSTextField(labelWithString: "预览文件"), files])
        let time = row([problemTimeToggle, problemTime])
        let buttons = row([checkButton, copyButton, previewButton, saveButton, cancelButton])
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        review.isEditable = false
        review.isSelectable = true
        review.isRichText = false
        review.setAccessibilityIdentifier("diagnostic-export-review")
        review.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        review.textContainerInset = NSSize(width: 10, height: 10)
        review.isVerticallyResizable = true
        review.isHorizontallyResizable = false
        review.autoresizingMask = [.width]
        review.textContainer?.widthTracksTextView = true
        review.string = "可直接生成最近 30 分钟的导出预览。当前检查：未执行。\n\n清除仅删除本应用拥有的诊断文件和临时快照；用户另存的 ZIP 和系统已接收的日志不属于清除范围。"
        scroll.documentView = review
        let stack = NSStackView(views: [status, explanation, recording, recordingStatus, descriptionInput, time, range, scroll, buttons])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        content.addSubview(stack)
        stack.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 20),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -20),
            explanation.widthAnchor.constraint(equalTo: stack.widthAnchor),
            descriptionInput.widthAnchor.constraint(equalTo: stack.widthAnchor),
            recordingStatus.widthAnchor.constraint(equalTo: stack.widthAnchor),
            scroll.widthAnchor.constraint(equalTo: stack.widthAnchor),
            scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 230)
        ])
        updateRecordingStatus()
        refreshButtons()
    }

    private func row(_ views: [NSView]) -> NSStackView {
        let stack = NSStackView(views: views)
        stack.orientation = .horizontal
        stack.spacing = 10
        return stack
    }

    private func updateRecordingStatus() {
        recordingToggle.state = recorder.isEnabled ? .on : .off
        recordingStatus.stringValue = recorder.isEnabled
            ? "记录已开启；实际覆盖范围及缺口会在导出预览中列明。"
            : "记录已关闭，保留已有文件；当前检查与显式导出仍可使用。"
        if failedRecordingValue != nil { recordingStatus.stringValue = "本进程记录\(recorder.isEnabled ? "开启" : "关闭")；跨进程记录状态尚未确认，请重试记录设置。" }
    }

    private func loadOverview() {
        let generation = revision
        let environment = self.environment
        let recorder = self.recorder
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let captured = environment()
            recorder.captureSnapshot(since: Date().addingTimeInterval(-1_800)) { result in
                let formatter = ISO8601DateFormatter()
                let coverage: String
                switch result {
                case .success(let store):
                    coverage = "最近 30 分钟的实际事件覆盖：\(store.earliest.map(formatter.string(from:)) ?? "无可用记录") → \(store.latest.map(formatter.string(from:)) ?? "无可用记录")；丢弃 \(store.droppedCount) 条。"
                case .failure: coverage = "事件读取未完成；仍可生成标明缺失项的导出快照。"
                }
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.revision == generation, self.snapshot == nil, !self.exporting else { return }
                    self.recordingStatus.stringValue += " " + coverage
                    if let report = self.runner.report {
                        self.review.string = captured.summaryText + "\n\n" + report.text
                    } else {
                        self.review.string = captured.summaryText + "\n\n当前检查：未执行。\n" + coverage + "\n\n清除仅处理本应用诊断记录；另存 ZIP 与系统日志不在清除范围。"
                    }
                }
            }
        }
    }

    private func refreshButtons() {
        let checking = runner.report?.isRunning == true
        checkButton.isEnabled = !checking && !exporting && !recordingChangePending
        copyButton.isEnabled = !checking && !exporting && (snapshot != nil || runner.report != nil)
        previewButton.isEnabled = !exporting && !recordingChangePending
        saveButton.isEnabled = snapshot != nil && !exporting && !recordingChangePending
        cancelButton.isEnabled = checking || exporting
        files.isEnabled = snapshot != nil && !exporting
        clearButton.isEnabled = !recordingChangePending
        recordingToggle.isEnabled = !recordingChangePending
        retryRecordingButton.isEnabled = !recordingChangePending
    }

    private func invalidatePreview() {
        revision &+= 1
        exporter.invalidate()
        exporting = false
        snapshot = nil
        files.removeAllItems()
        refreshButtons()
    }

    private func update(_ report: ConnectionDiagnosticsReport) {
        if snapshot == nil && !exporting {
            status.stringValue = report.summary
            review.string = report.text
        }
        refreshButtons()
    }

    @objc private func checkAgain() { startCheck() }
    @objc private func changeProblemTime() {
        problemTime.isEnabled = problemTimeToggle.state == .on
        exportInputsChanged()
    }
    func controlTextDidChange(_ notification: Notification) { exportInputsChanged() }
    @objc private func exportInputsChanged() {
        guard snapshot != nil || exporting else { return }
        invalidatePreview()
        status.stringValue = "导出输入已变化，旧快照已失效；请重新生成预览。"
        review.string = "请重新生成导出预览以包含当前说明、发生时间和范围。"
    }
    @objc private func selectFile() {
        guard let snapshot, snapshot.files.indices.contains(files.indexOfSelectedItem) else { return }
        review.string = snapshot.files[files.indexOfSelectedItem].text
    }
    @objc private func copyReport() {
        guard runner.report?.isRunning != true, !exporting else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(review.string, forType: .string)
        status.stringValue = "当前预览文本已复制"
    }

    @objc private func generatePreview() {
        invalidatePreview()
        let selected = DiagnosticExportRange.allCases[max(0, ranges.indexOfSelectedItem)]
        let request = DiagnosticExportRequest(range: selected, problemDescription: descriptionInput.stringValue,
            problemTime: problemTimeToggle.state == .on ? problemTime.dateValue : nil)
        let generation = revision
        exporting = true
        status.stringValue = "正在后台生成快照…（最多 30 秒，可取消）"
        refreshButtons()
        exporter.preview(request: request, report: runner.report) { [weak self] result in
            guard let self, self.revision == generation else { return }
            self.exporting = false
            switch result {
            case .success(let snapshot):
                self.snapshot = snapshot
                self.files.addItems(withTitles: snapshot.files.map { "\($0.name)（\($0.data.count) 字节）" })
                self.files.selectItem(at: 0)
                self.selectFile()
                self.status.stringValue = "预览已冻结：5 个文件，\(snapshot.byteCount) 字节。\(snapshot.hasGaps ? "存在覆盖不足或采集缺口，请审阅摘要。" : "可保存预览中的全部内容。")"
            case .failure(let error): self.status.stringValue = error.message
            }
            self.refreshButtons()
        }
    }

    @objc private func saveZIP() {
        guard let snapshot, let window, !exporting else { return }
        let generation = revision
        let panel = NSSavePanel()
        panel.allowedFileTypes = ["zip"]
        panel.nameFieldStringValue = snapshot.suggestedFileName
        panel.title = "保存已预览的诊断包"
        panel.beginSheetModal(for: window) { [weak self] response in
            guard let self, self.revision == generation else { return }
            guard response == .OK, let url = panel.url else { self.status.stringValue = "保存已取消，预览仍可审阅。"; return }
            self.exporting = true
            self.status.stringValue = "正在保存并校验 ZIP…（最多 30 秒，可取消）"
            self.refreshButtons()
            self.exporter.save(snapshot, to: url) { [weak self] result in
                guard let self, self.revision == generation else { return }
                self.exporting = false
                switch result {
                case .success: self.status.stringValue = "诊断包已保存，ZIP 可读性及文件内容校验通过。"
                case .failure(let error): self.status.stringValue = error.message
                }
                self.refreshButtons()
            }
        }
    }

    @objc private func cancelDiagnostics() {
        exporter.cancel()
        runner.cancel()
    }

    @objc private func changeRecording() {
        applyRecordingChange(recordingToggle.state == .on)
    }

    @objc private func retryRecordingChange() {
        guard let value = failedRecordingValue else { return }
        applyRecordingChange(value)
    }

    private func applyRecordingChange(_ enabled: Bool) {
        guard !recordingChangePending else { return }
        invalidatePreview()
        let generation = revision
        recordingChangePending = true
        failedRecordingValue = nil
        retryRecordingButton.isHidden = true
        status.stringValue = "正在更新记录设置；等待跨进程控制确认…"
        refreshButtons()
        recorder.setEnabledReporting(enabled) { [weak self] result in
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.recordingChangePending = false
                switch result {
                case .success(let effective):
                    self.defaults.set(effective, forKey: DiagnosticRecorder.preferenceKey)
                    self.failedRecordingValue = nil
                    if self.revision == generation { self.status.stringValue = "记录状态已更新，跨进程控制已确认；旧预览已失效。" }
                case .failure:
                    self.failedRecordingValue = enabled
                    if self.revision == generation { self.status.stringValue = "记录设置尚未确认，跨进程记录状态可能未更新；未保存偏好。请重试。" }
                }
                self.retryRecordingButton.isHidden = self.failedRecordingValue == nil
                self.updateRecordingStatus()
                self.refreshButtons()
            }
        }
    }

    @objc private func clearRecords() {
        invalidatePreview()
        review.string = "旧预览已失效。清除仅处理本应用的诊断记录；另存 ZIP 与系统日志不在清除范围。"
        status.stringValue = "正在清除本地诊断记录…"
        let generation = revision
        recorder.clear { [weak self] result in
            DispatchQueue.main.async { [weak self] in
                guard let self, self.revision == generation else { return }
                switch result {
                case .success: self.status.stringValue = "本地诊断记录已清除；旧预览已失效。"
                case .failure: self.status.stringValue = "部分诊断文件未能清除，请检查目录权限；旧预览已失效。"
                }
                self.updateRecordingStatus()
            }
        }
    }
}
