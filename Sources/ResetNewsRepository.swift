import Foundation
import ResetNewsCore

struct ResetNewsStoredState: Codable, Equatable {
    var version = 1
    var items: [ResetNewsItem] = []
    var readIDs: Set<String> = []
    var notified: [ResetNewsNotificationRecord] = []
    var baselineSources: [ResetNewsSource] = []
    var retiredForecasts: [ResetForecastRetirement]?
    // Optional additions keep existing v1 caches readable. Legacy history is not
    // evidence that the current-forecast endpoint has established its baseline.
    var forecast: ResetForecastSnapshot?
    var forecastFetchedAt: Date?
    var forecastExpiresAt: Date?
    var forecastBaselineEstablished: Bool?

    var hasBaseline: Bool { !baselineSources.isEmpty }
    var notifiedKeys: Set<String> { Set(notified.map(\.key)) }
}

/// Injectable disk access; invoked only on the repository's serial I/O queue.
struct ResetNewsCacheStorage {
    var read: (URL) throws -> Data? = { url in
        do { return try Data(contentsOf: url) }
        catch let error as NSError where error.domain == NSCocoaErrorDomain
            && (error.code == NSFileNoSuchFileError || error.code == NSFileReadNoSuchFileError) { return nil }
    }
    var write: (Data, URL) throws -> Void = { data, url in
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
    }
}

/// The in-memory snapshot belongs to main. Disk reads, encoding and ordered writes belong to ioQueue.
final class ResetNewsRepository {
    let fileURL: URL
    private(set) var state = ResetNewsStoredState()
    private(set) var recoveredCorruptCache = false
    private(set) var lastPersistenceError: String?
    private(set) var isLoaded = false
    var onPersistenceChange: (() -> Void)?
    private let calendar: () -> Calendar
    private let initialDate: Date
    private let storage: ResetNewsCacheStorage
    private let ioQueue: DispatchQueue
    private var loading = false
    private var loadCallbacks: [() -> Void] = []
    private var persistenceRevision = 0

    init(directory: URL? = nil, bundleIdentifier: String = Bundle.main.bundleIdentifier ?? "io.github.zz-zed.GPTTouchBarHUD",
         fileManager: FileManager = .default, now: Date = Date(), calendar: @escaping () -> Calendar = { .current },
         storage: ResetNewsCacheStorage = ResetNewsCacheStorage(),
         ioQueue: DispatchQueue = DispatchQueue(label: "io.github.zz-zed.GPTTouchBarHUD.news-cache", qos: .utility)) {
        precondition(Thread.isMainThread)
        self.calendar = calendar
        initialDate = now
        self.storage = storage
        self.ioQueue = ioQueue
        let support = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support", isDirectory: true)
        let root = directory ?? support.appendingPathComponent(bundleIdentifier, isDirectory: true)
            .appendingPathComponent("ResetNews", isDirectory: true)
        fileURL = root.appendingPathComponent("state-v1.json")
    }

    /// Gates the first network check on loading the existing notification ledger.
    func load(completion: @escaping () -> Void) {
        precondition(Thread.isMainThread)
        if isLoaded { completion(); return }
        loadCallbacks.append(completion)
        guard !loading else { return }
        loading = true
        let file = fileURL, storage = self.storage
        ioQueue.async {
            let result = Result<ResetNewsStoredState, Error> {
                guard let data = try storage.read(file) else { return ResetNewsStoredState() }
                let decoded = try JSONDecoder().decode(ResetNewsStoredState.self, from: data)
                guard decoded.version == 1, Set(decoded.items.map(\.id)).count == decoded.items.count else {
                    throw CocoaError(.fileReadCorruptFile)
                }
                return decoded
            }
            DispatchQueue.main.async {
                switch result {
                case .success(let decoded):
                    self.state = decoded
                    self.prune(now: self.initialDate)
                    if self.state != decoded {
                        // Complete migration on disk before allowing a fresh check.
                        self.persist { _ in self.finishLoading() }
                        return
                    }
                case .failure:
                    self.recoveredCorruptCache = true
                    self.lastPersistenceError = "消息缓存损坏，下一次成功检查将重建历史基线。"
                }
                self.finishLoading()
            }
        }
    }

    private func finishLoading() {
        isLoaded = true
        loading = false
        let callbacks = loadCallbacks
        loadCallbacks.removeAll()
        callbacks.forEach { $0() }
    }

    func replace(_ newState: ResetNewsStoredState, now: Date, completion: @escaping (Bool) -> Void) {
        precondition(Thread.isMainThread && isLoaded)
        state = newState
        prune(now: now)
        persist(completion: completion)
    }

    func markRead(_ ids: Set<String>, now: Date = Date()) {
        precondition(Thread.isMainThread)
        guard isLoaded else { return }
        let previous = state
        state.readIDs.formUnion(ids.intersection(readableIDs(now: now)))
        prune(now: now)
        if state != previous { persist() }
    }

    func markAllRead(now: Date = Date()) {
        markRead(readableIDs(now: now), now: now)
    }

    func recordNotifications(_ keys: Set<String>, now: Date, completion: @escaping (Bool) -> Void) {
        precondition(Thread.isMainThread && isLoaded)
        let existing = state.notifiedKeys
        state.notified.append(contentsOf: keys.subtracting(existing).map { .init(key: $0, recordedAt: now) })
        prune(now: now)
        persist(completion: completion)
    }

    func refreshLocalForecasts(now: Date) {
        precondition(Thread.isMainThread)
        guard isLoaded else { return }
        let previous = state
        prune(now: now)
        if state != previous { persist() }
    }

    /// An asynchronous fence for shutdown and isolated reload checks.
    func flush(completion: @escaping () -> Void) {
        load {
            self.ioQueue.async { DispatchQueue.main.async(execute: completion) }
        }
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
        state.readIDs.formIntersection(readableIDs(now: now))
        var keys: Set<String> = []
        state.notified = Array(state.notified.filter { $0.recordedAt >= now.addingTimeInterval(-90 * 86_400) }
            .sorted { $0.recordedAt > $1.recordedAt }.filter { keys.insert($0.key).inserted }.prefix(500))
        var sources: [ResetNewsSource] = []
        for source in state.baselineSources where !sources.contains(source) { sources.append(source) }
        state.baselineSources = sources
    }

    private func readableIDs(now: Date) -> Set<String> {
        var ids = Set(state.items.map(\.id))
        if let item = state.forecast?.item(now: now, calendar: calendar()) { ids.insert(item.id) }
        return ids
    }

    private func persist(completion: ((Bool) -> Void)? = nil) {
        persistenceRevision += 1
        let revision = persistenceRevision
        let snapshot = state, file = fileURL, storage = self.storage
        ioQueue.async {
            let result = Result<Void, Error> {
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.sortedKeys]
                try storage.write(encoder.encode(snapshot), file)
            }
            DispatchQueue.main.async {
                let saved: Bool
                let error: String?
                switch result {
                case .success: saved = true; error = nil
                case .failure(let failure): saved = false; error = "消息缓存保存失败：\(failure.localizedDescription)"
                }
                if revision == self.persistenceRevision {
                    self.lastPersistenceError = error
                    self.onPersistenceChange?()
                }
                completion?(saved)
            }
        }
    }
}
