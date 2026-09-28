import Foundation

protocol ConnectionDiagnosticsClient: AccountUsageClient {
    func start(completion: @escaping (Result<Void, Error>) -> Void)
    func stop()
    func readRateLimits(completion: @escaping (Result<GetAccountRateLimitsResponse, Error>) -> Void)
}

extension CodexAppServerClient: ConnectionDiagnosticsClient {}

enum ConnectionDiagnosticStep: Int, CaseIterable {
    case runtime, connection, account, rateLimits, tokenUsage, accountConsistency

    var title: String {
        switch self {
        case .runtime: return "查找宿主内置程序"
        case .connection: return "建立连接"
        case .account: return "检查登录状态"
        case .rateLimits: return "读取额度接口"
        case .tokenUsage: return "读取 Token 接口"
        case .accountConsistency: return "复核登录状态"
        }
    }
}

/// All user-visible outcomes are fixed strings. Raw errors and account responses never enter a report.
enum ConnectionDiagnosticFinding: Equatable {
    case waiting, checking, passed, signedIn, signedOut, noData
    case runtimeMissing, unavailable, timedOut, invalidResponse, serviceRejected, unexpectedFailure
    case prerequisiteFailed, accountUnverified, accountChanged, cancelled

    var label: String {
        switch self {
        case .waiting: return "待检查"
        case .checking: return "检查中"
        case .passed: return "通过"
        case .signedIn: return "已登录"
        case .signedOut: return "未登录"
        case .noData: return "接口可用，暂未返回可用数据"
        case .runtimeMissing: return "未找到可用的宿主内置程序"
        case .unavailable: return "连接不可用"
        case .timedOut: return "请求超时"
        case .invalidResponse: return "响应格式不兼容"
        case .serviceRejected: return "服务未完成请求"
        case .unexpectedFailure: return "检查未完成"
        case .prerequisiteFailed: return "未执行：前置检查未通过"
        case .accountUnverified: return "无法确认账号，结果待复核"
        case .accountChanged: return "检查期间账号发生变化，结果已作废"
        case .cancelled: return "已取消"
        }
    }

    var recommendation: String? {
        switch self {
        case .runtimeMissing: return "请确认 ChatGPT 或 Codex 已安装，并更新至可正常打开的版本。"
        case .unavailable: return "请确认宿主可正常打开，再重新检查连接。"
        case .signedOut: return "请在 ChatGPT 或 Codex 中完成登录，再重新检查。"
        case .timedOut: return "请检查网络与宿主是否正常，稍后重试。"
        case .invalidResponse: return "请更新宿主与 HUD；若仍失败，可复制本报告用于排查。"
        case .serviceRejected: return "请确认宿主已登录、网络正常，并检查宿主是否有更新后重试。"
        case .unexpectedFailure: return "请重新检查；若仍失败，可复制本报告用于排查。"
        case .noData: return "请稍后刷新；接口可用不代表当前账号已有统计数据。"
        case .accountUnverified, .accountChanged: return "请完成账号切换或登录操作后，重新检查。"
        case .waiting, .checking, .passed, .signedIn, .prerequisiteFailed, .cancelled: return nil
        }
    }

    var needsAttention: Bool {
        switch self {
        case .passed, .signedIn, .waiting, .checking, .cancelled: return false
        default: return true
        }
    }

    static func classify(_ error: Error) -> Self {
        if let error = error as? CodexAppServerError {
            switch error {
            case .runtimeNotFound: return .runtimeMissing
            case .processUnavailable: return .unavailable
            case .requestTimedOut: return .timedOut
            case .malformedResponse, .missingResult, .responseTooLarge: return .invalidResponse
            case .serverError: return .serviceRejected
            }
        }
        if error is DecodingError { return .invalidResponse }
        return .unexpectedFailure
    }
}

struct ConnectionDiagnosticsEnvironment {
    enum Host: String {
        case chatGPT = "ChatGPT", codex = "Codex", gpt = "GPT", unknown = "未识别"
    }
    enum Architecture: String { case arm64, x86_64, unknown = "未知" }

    let appVersion: String
    let operatingSystem: OperatingSystemVersion
    let architecture: Architecture
    let host: Host
    let hostVersion: String

    init(appVersion: String?, operatingSystem: OperatingSystemVersion,
         architecture: Architecture, host: Host, hostVersion: String?) {
        self.appVersion = Self.safeVersion(appVersion)
        self.operatingSystem = operatingSystem
        self.architecture = architecture
        self.host = host
        self.hostVersion = Self.safeVersion(hostVersion)
    }

    static func current(runtime: URL?) -> Self {
        var host = Host.unknown
        var hostVersion: String?
        if var bundleURL = runtime {
            while bundleURL.path != "/" {
                switch bundleURL.lastPathComponent {
                case "ChatGPT.app": host = .chatGPT
                case "Codex.app": host = .codex
                case "GPT.app": host = .gpt
                default: break
                }
                if host != .unknown {
                    hostVersion = Bundle(url: bundleURL)?.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
                    break
                }
                bundleURL.deleteLastPathComponent()
            }
        }
        #if arch(arm64)
        let architecture = Architecture.arm64
        #elseif arch(x86_64)
        let architecture = Architecture.x86_64
        #else
        let architecture = Architecture.unknown
        #endif
        return Self(appVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
                    operatingSystem: ProcessInfo.processInfo.operatingSystemVersion,
                    architecture: architecture, host: host, hostVersion: hostVersion)
    }

    private static func safeVersion(_ value: String?) -> String {
        guard let value, !value.isEmpty, value.utf8.count <= 40,
              value.utf8.allSatisfy({ (48...57).contains($0) || $0 == 46 }),
              value.utf8.contains(where: { (48...57).contains($0) }) else { return "未知" }
        return value
    }
}

struct ConnectionDiagnosticsReport {
    let environment: ConnectionDiagnosticsEnvironment
    let startedAt: Date
    var finishedAt: Date?
    var findings: [ConnectionDiagnosticStep: ConnectionDiagnosticFinding]

    var isRunning: Bool { finishedAt == nil }
    var summary: String {
        if isRunning { return "正在检查连接…" }
        if findings.values.contains(.cancelled) { return "检查已取消" }
        if findings.values.contains(where: { $0.needsAttention }) { return "检查完成，部分项目需要关注" }
        return "检查完成，连接与账号接口正常"
    }

    var text: String {
        let os = environment.operatingSystem
        let formatter = ISO8601DateFormatter()
        var lines = [
            "GPT TouchBar HUD 连接诊断",
            "App 版本：\(environment.appVersion)",
            "系统：macOS \(os.majorVersion).\(os.minorVersion).\(os.patchVersion)",
            "架构：\(environment.architecture.rawValue)",
            "宿主：\(environment.host.rawValue) \(environment.hostVersion)",
            "数据来源：宿主内置 Codex 的账号接口（本次按需检查）",
            "开始时间：\(formatter.string(from: startedAt))"
        ]
        if let finishedAt { lines.append("结束时间：\(formatter.string(from: finishedAt))") }
        lines.append("状态：\(summary)")
        lines.append("")
        for step in ConnectionDiagnosticStep.allCases {
            let finding = findings[step] ?? .waiting
            lines.append("\(step.rawValue + 1). \(step.title)：\(finding.label)")
            if let recommendation = finding.recommendation { lines.append("   建议：\(recommendation)") }
        }
        return lines.joined(separator: "\n")
    }
}

/// Main-thread coordinator for a separate, short-lived connection. Nothing runs until startCheck().
final class ConnectionDiagnosticsRunner {
    private let locateRuntime: () -> URL?
    private let makeClient: (URL) -> ConnectionDiagnosticsClient
    private let environment: (URL?) -> ConnectionDiagnosticsEnvironment
    private let now: () -> Date
    private var client: ConnectionDiagnosticsClient?
    private var generation = 0
    private var identity: String?
    private(set) var report: ConnectionDiagnosticsReport?
    var onUpdate: ((ConnectionDiagnosticsReport) -> Void)?

    init(locateRuntime: @escaping () -> URL? = { CodexRuntimeLocator.locate() },
         makeClient: @escaping (URL) -> ConnectionDiagnosticsClient = { CodexAppServerClient(executableURL: $0) },
         environment: @escaping (URL?) -> ConnectionDiagnosticsEnvironment = ConnectionDiagnosticsEnvironment.current,
         now: @escaping () -> Date = Date.init) {
        self.locateRuntime = locateRuntime
        self.makeClient = makeClient
        self.environment = environment
        self.now = now
    }

    deinit { client?.stop() }

    func startCheck() {
        precondition(Thread.isMainThread)
        invalidate()
        let revision = generation
        let runtime = locateRuntime()
        report = ConnectionDiagnosticsReport(environment: environment(runtime), startedAt: now(),
            findings: Dictionary(uniqueKeysWithValues: ConnectionDiagnosticStep.allCases.map { ($0, .waiting) }))
        guard let runtime else {
            set(.runtime, .runtimeMissing)
            skipWaiting()
            finish()
            return
        }
        set(.runtime, .passed)
        let connection = makeClient(runtime)
        client = connection
        set(.connection, .checking)
        publish()
        guard generation == revision else { return }
        connection.start { [weak self] result in
            self?.receive(revision) { runner in
                switch result {
                case .failure(let error):
                    runner.set(.connection, .classify(error))
                    runner.skipWaiting()
                    runner.finish()
                case .success:
                    runner.set(.connection, .passed)
                    runner.checkIdentity(revision)
                }
            }
        }
    }

    func cancel() {
        precondition(Thread.isMainThread)
        let wasRunning = report?.isRunning == true
        invalidate()
        guard wasRunning else { return }
        for step in ConnectionDiagnosticStep.allCases {
            if report?.findings[step] == .waiting || report?.findings[step] == .checking { set(step, .cancelled) }
        }
        report?.finishedAt = now()
        publish()
    }

    private func invalidate() {
        generation += 1
        identity = nil
        client?.stop()
        client = nil
    }

    private func checkIdentity(_ revision: Int) {
        set(.account, .checking)
        publish()
        guard generation == revision else { return }
        client?.readAccountIdentity { [weak self] result in
            self?.receive(revision) { runner in
                switch result {
                case .failure(let error):
                    runner.set(.account, .classify(error))
                    runner.skipWaiting()
                    runner.finish()
                case .success(nil):
                    runner.set(.account, .signedOut)
                    runner.skipWaiting()
                    runner.finish()
                case .success(let identity?):
                    runner.identity = identity
                    runner.set(.account, .signedIn)
                    runner.checkRateLimits(revision)
                }
            }
        }
    }

    private func checkRateLimits(_ revision: Int) {
        set(.rateLimits, .checking)
        publish()
        guard generation == revision else { return }
        client?.readRateLimits { [weak self] result in
            self?.receive(revision) { runner in
                switch result {
                case .failure(let error): runner.set(.rateLimits, .classify(error))
                case .success(let response):
                    let snapshots = [response.rateLimits] + Array(response.rateLimitsByLimitId?.values ?? [:].values)
                    let hasData = response.rateLimitResetCredits != nil
                        || snapshots.contains { $0.primary != nil || $0.secondary != nil || $0.credits != nil }
                    runner.set(.rateLimits, hasData ? .passed : .noData)
                }
                runner.checkTokenUsage(revision)
            }
        }
    }

    private func checkTokenUsage(_ revision: Int) {
        set(.tokenUsage, .checking)
        publish()
        guard generation == revision else { return }
        client?.readTokenUsage { [weak self] result in
            self?.receive(revision) { runner in
                switch result {
                case .failure(let error): runner.set(.tokenUsage, .classify(error))
                case .success(let response):
                    let hasData = response.summary.lifetimeTokens.map { $0 >= 0 } == true
                        || response.dailyUsageBuckets?.contains(where: { $0.tokens >= 0 }) == true
                    runner.set(.tokenUsage, hasData ? .passed : .noData)
                }
                runner.recheckIdentity(revision)
            }
        }
    }

    private func recheckIdentity(_ revision: Int) {
        set(.accountConsistency, .checking)
        publish()
        guard generation == revision else { return }
        client?.readAccountIdentity { [weak self] result in
            self?.receive(revision) { runner in
                let finding: ConnectionDiagnosticFinding
                switch result {
                case .success(let current?): finding = current == runner.identity ? .passed : .accountChanged
                case .success(nil): finding = .accountChanged
                case .failure: finding = .accountUnverified
                }
                runner.set(.accountConsistency, finding)
                if finding != .passed {
                    runner.set(.account, finding)
                    runner.set(.rateLimits, finding)
                    runner.set(.tokenUsage, finding)
                }
                runner.finish()
            }
        }
    }

    private func receive(_ revision: Int, action: @escaping (ConnectionDiagnosticsRunner) -> Void) {
        if !Thread.isMainThread {
            DispatchQueue.main.async { [weak self] in self?.receive(revision, action: action) }
            return
        }
        guard generation == revision, report?.isRunning == true else { return }
        action(self)
    }

    private func set(_ step: ConnectionDiagnosticStep, _ finding: ConnectionDiagnosticFinding) {
        report?.findings[step] = finding
    }

    private func skipWaiting() {
        for step in ConnectionDiagnosticStep.allCases where report?.findings[step] == .waiting {
            set(step, .prerequisiteFailed)
        }
    }

    private func finish() {
        report?.finishedAt = now()
        invalidate()
        publish()
    }

    private func publish() {
        if let report { onUpdate?(report) }
    }
}
