import AppKit
import HookCore

/// Separate, default-off settings window. Nothing is installed or written until Apply is clicked.
final class HookExperimentPreferencesController: NSWindowController {
    var onModeChange: ((Bool) -> Void)?
    private let target: URL
    private let helper: URL
    private let directory: URL
    private let defaults: UserDefaults
    private var plan: HookConfigurationPlan?
    private let enabled = NSButton(checkboxWithTitle: "启用实验性任务监测", target: nil, action: nil)
    private let status = NSTextField(wrappingLabelWithString: "")
    private let review = NSTextView()
    private let apply = NSButton(title: "应用已审阅配置并启用", target: nil, action: nil)
    private let prepare = NSButton(title: "生成接入配置供审阅", target: nil, action: nil)
    private let cleanup = NSButton(title: "审阅本工具配置清理", target: nil, action: nil)
    private let work = DispatchQueue(label: "GPTTouchBarHUD.hook-configuration", qos: .utility)

    init(target: URL = URL(fileURLWithPath: ProcessInfo.processInfo.environment["CODEX_HOME"] ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex").path).appendingPathComponent("hooks.json"),
         helper: URL = HookPaths.stableHelper, directory: URL = HookPaths.defaultDirectory, defaults: UserDefaults = .standard) {
        self.target = target; self.helper = helper; self.directory = directory; self.defaults = defaults
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 680, height: 510), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = "实验性任务监测 · Hooks"; window.isReleasedWhenClosed = false
        super.init(window: window); configure(); window.center()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    private func configure() {
        guard let content = window?.contentView else { return }
        enabled.state = defaults.bool(forKey: "hookTaskMonitoringEnabled") ? .on : .off
        enabled.target = self; enabled.action = #selector(toggle)
        prepare.target = self; prepare.action = #selector(prepareInstall)
        cleanup.target = self; cleanup.action = #selector(prepareRemoval)
        apply.target = self; apply.action = #selector(applyPlan); apply.isEnabled = false
        status.stringValue = "默认关闭。启用后须在 Codex 的 /hooks 或宿主 Hooks 页面审阅并信任。接收正常不代表覆盖全部任务；可能显示 — 或 2 ?。关闭立即恢复日志模式；清理仅移除本工具未被修改的四项定义。"
        status.font = .systemFont(ofSize: 12)
        let row = NSStackView(views: [prepare, cleanup]); row.orientation = .horizontal
        let scroll = NSScrollView(); scroll.hasVerticalScroller = true; scroll.borderType = .bezelBorder
        review.isEditable = false; review.isSelectable = true; review.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        review.autoresizingMask = [.width]; review.textContainer?.widthTracksTextView = true
        scroll.documentView = review
        let stack = NSStackView(views: [enabled, status, row, scroll, apply]); stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 12
        content.addSubview(stack); stack.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20), stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20), stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 20), stack.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -20), scroll.widthAnchor.constraint(equalTo: stack.widthAnchor), scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 270)])
    }
    @objc private func toggle() {
        if enabled.state == .off {
            defaults.set(false, forKey: "hookTaskMonitoringEnabled"); onModeChange?(false)
            status.stringValue = "实验已关闭，恢复日志模式。配置尚未删除；可审阅下方清理计划。残留 Hook 在 HUD 未接收时中性退出。"
        } else {
            // Checking the box only requests a plan; successful Apply persists the preference.
            enabled.state = .off; prepareInstall()
        }
    }
    @objc private func prepareInstall() { makePlan(removing: false) }
    @objc private func prepareRemoval() { makePlan(removing: true) }
    private func makePlan(removing: Bool) {
        setBusy(true)
        let target = target, helper = helper, socket = directory.appendingPathComponent("events.sock")
        work.async { [weak self] in
            let result = Result { () -> HookConfigurationPlan in
                let plan = try HookConfiguration.plan(target: target, helper: helper, socket: socket, removing: removing)
                if !removing {
                    let candidates = ["/Applications/ChatGPT.app/Contents/Resources/codex", "/Applications/Codex.app/Contents/Resources/codex", "/Applications/GPT.app/Contents/Resources/codex"]
                    guard let path = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else { throw HookFailure.unavailable }
                    _ = try HookHostPreflight.discover(runtime: URL(fileURLWithPath: path), plan: plan)
                }
                return plan
            }
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }; self.setBusy(false)
                switch result {
                case .success(let plan):
                    self.plan = plan; self.review.string = plan.reviewText
                    self.apply.title = removing ? "应用已审阅清理并关闭" : "应用已审阅配置并启用"
                    self.apply.isEnabled = true
                    self.status.stringValue = "已核验隔离实例能发现配置（清理不需核验宿主）。请核对文件路径、命令与完整合并结果。应用前将备份原文件并校验，应用后解析读回。不会修改宿主信任记录。"
                case .failure:
                    self.plan = nil; self.apply.isEnabled = false
                    self.status.stringValue = "无法安全生成计划：请检查宿主 Hooks 支持、配置目录、JSON 格式或是否已有被修改的本工具条目。未写入配置。"
                }
            }
        }
    }
    @objc private func applyPlan() {
        guard let plan else { return }; setBusy(true)
        let destination = helper, directory = directory
        let bundled = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/HookEmitter")
        work.async { [weak self] in
            let result = Result { () -> URL? in
                if !plan.removing {
                    // Compare again before any installation; applying stale review requires regeneration.
                    let current = try HookConfiguration.plan(target: plan.target, helper: destination, socket: directory.appendingPathComponent("events.sock"))
                    guard current.original == plan.original else { throw HookFailure.changed }
                    _ = try HookHelperInstaller.install(bundledHelper: bundled, destination: destination)
                    try HookPaths.ensurePrivateDirectory(directory)
                }
                return try HookConfiguration.apply(plan)
            }
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }; self.setBusy(false)
                switch result {
                case .success(let backup):
                    let isEnabled = !plan.removing
                    self.defaults.set(isEnabled, forKey: "hookTaskMonitoringEnabled"); self.enabled.state = isEnabled ? .on : .off
                    self.onModeChange?(isEnabled); self.plan = nil; self.apply.isEnabled = false
                    self.status.stringValue = (isEnabled ? "配置已写入并读回。请在宿主正常审阅并信任；已有任务可能需要重新进入。等待事件不等于信任已通过。" : "已清理精确匹配的本工具定义并恢复日志模式；其他或被修改的条目保留。") + (backup.map { "\n备份：" + $0.path } ?? "")
                case .failure:
                    self.status.stringValue = "应用未完成，监测偏好未更改。可能是配置已变化、路径权限或 helper 签名检查失败。若 helper 已复制，配置备份与 helper 回滚文件会保留供检查；请重新生成计划。"
                }
            }
        }
    }
    private func setBusy(_ busy: Bool) {
        enabled.isEnabled = !busy; prepare.isEnabled = !busy; cleanup.isEnabled = !busy; apply.isEnabled = !busy && plan != nil
    }
}
