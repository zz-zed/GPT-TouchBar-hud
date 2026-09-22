import Foundation
import ResetNewsCore

struct ResetNewsStoredState: Codable, Equatable {
    var version = 1
    var items: [ResetNewsItem] = []
    var readIDs: Set<String> = []
    var notified: [ResetNewsNotificationRecord] = []
    var baselineSources: [ResetNewsSource] = []
    var retiredForecasts: [ResetForecastRetirement]?

    var hasBaseline: Bool { !baselineSources.isEmpty }
    var notifiedKeys: Set<String> { Set(notified.map(\.key)) }
}

/// Small, bounded snapshot. All callers are serialized by ResetNewsMonitor on the main thread.
final class ResetNewsRepository {
    let fileURL: URL
    private(set) var state = ResetNewsStoredState()
    private(set) var recoveredCorruptCache = false
    private(set) var lastPersistenceError: String?
    private let fileManager: FileManager
    private let calendar: () -> Calendar

    init(directory: URL? = nil, bundleIdentifier: String = Bundle.main.bundleIdentifier ?? "io.github.zz-zed.GPTTouchBarHUD",
         fileManager: FileManager = .default, now: Date = Date(), calendar: @escaping () -> Calendar = { .current }) {
        self.fileManager = fileManager
        self.calendar = calendar
        let support = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support", isDirectory: true)
        let root = directory ?? support.appendingPathComponent(bundleIdentifier, isDirectory: true)
            .appendingPathComponent("ResetNews", isDirectory: true)
        fileURL = root.appendingPathComponent("state-v1.json")
        guard fileManager.fileExists(atPath: fileURL.path) else { return }
        do {
            let data = try Data(contentsOf: fileURL)
            let decoded = try JSONDecoder().decode(ResetNewsStoredState.self, from: data)
            guard decoded.version == 1, Set(decoded.items.map(\.id)).count == decoded.items.count else {
                throw CocoaError(.fileReadCorruptFile)
            }
            state = decoded
            prune(now: now)
            // Migrate the existing v1 snapshot on disk, not only the visible projection.
            if state != decoded { _ = persist() }
        } catch {
            // Losing the notification ledger requires a fresh, silent source baseline.
            recoveredCorruptCache = true
            lastPersistenceError = "消息缓存损坏，下一次成功检查将重建历史基线。"
            state = ResetNewsStoredState()
        }
    }

    @discardableResult
    func replace(_ newState: ResetNewsStoredState, now: Date) -> Bool {
        state = newState
        prune(now: now)
        return persist()
    }

    @discardableResult
    func markRead(_ ids: Set<String>, now: Date = Date()) -> Bool {
        state.readIDs.formUnion(ids.intersection(Set(state.items.map(\.id))))
        prune(now: now)
        return persist()
    }

    @discardableResult
    func markAllRead(now: Date = Date()) -> Bool {
        markRead(Set(state.items.map(\.id)), now: now)
    }

    @discardableResult
    func recordNotifications(_ keys: Set<String>, now: Date) -> Bool {
        let existing = state.notifiedKeys
        state.notified.append(contentsOf: keys.subtracting(existing).map { .init(key: $0, recordedAt: now) })
        prune(now: now)
        return persist()
    }

    @discardableResult
    func refreshLocalForecasts(now: Date) -> Bool {
        let previous = state
        prune(now: now)
        return state == previous ? true : persist()
    }

    private func prune(now: Date) {
        let policy = ResetForecastPolicy(calendar: calendar())
        var retired: [String: ResetForecastRetirement] = [:]
        for entry in state.retiredForecasts ?? [] where entry.retainUntil > now { retired[entry.id] = entry }
        for item in state.items where policy.isConfirmedTerminal(item) && policy.retaining(item, now: now) == nil {
            var entry = policy.retirement(for: item, now: now)
            if let old = retired[item.id] {
                entry.versionAt = max(entry.versionAt, old.versionAt)
                entry.retainUntil = max(entry.retainUntil, old.retainUntil)
                entry.revision = max(entry.revision, old.revision)
            }
            retired[item.id] = entry
        }
        state.items = policy.retaining(state.items, now: now)
        state.retiredForecasts = retired.values.sorted { $0.id < $1.id }
        state.readIDs.formIntersection(Set(state.items.map(\.id)))
        var keys: Set<String> = []
        state.notified = Array(state.notified.filter { $0.recordedAt >= now.addingTimeInterval(-90 * 86_400) }
            .sorted { $0.recordedAt > $1.recordedAt }.filter { keys.insert($0.key).inserted }.prefix(500))
        var sources: [ResetNewsSource] = []
        for source in state.baselineSources where !sources.contains(source) { sources.append(source) }
        state.baselineSources = sources
    }

    private func persist() -> Bool {
        do {
            try fileManager.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            try encoder.encode(state).write(to: fileURL, options: .atomic)
            lastPersistenceError = nil
            return true
        } catch {
            lastPersistenceError = "消息缓存保存失败：\(error.localizedDescription)"
            return false
        }
    }
}
