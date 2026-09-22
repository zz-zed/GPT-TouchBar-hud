import Foundation

public struct ResetNewsNotificationRecord: Codable, Equatable, Sendable {
    public var key: String
    public var recordedAt: Date
    public init(key: String, recordedAt: Date) { self.key = key; self.recordedAt = recordedAt }
}

public struct ResetNewsState: Codable, Equatable, Sendable {
    public var items: [ResetNewsItem]
    public var notificationRecords: [ResetNewsNotificationRecord]
    public var hasBaseline: Bool
    public var retiredForecasts: [ResetForecastRetirement]?
    public init(items: [ResetNewsItem] = [], notificationRecords: [ResetNewsNotificationRecord] = [], hasBaseline: Bool = false,
                retiredForecasts: [ResetForecastRetirement]? = nil) {
        self.items = items
        self.notificationRecords = notificationRecords
        self.hasBaseline = hasBaseline
        self.retiredForecasts = retiredForecasts
    }
}

public struct ResetNewsRetentionPolicy: Codable, Equatable, Sendable {
    public var notificationFreshness: TimeInterval
    public var historyRetention: TimeInterval
    public var maximumHistoryCount: Int
    public var notificationRetention: TimeInterval
    public var maximumNotificationRecords: Int

    public init(notificationFreshness: TimeInterval = 6 * 60 * 60,
                historyRetention: TimeInterval = 30 * 24 * 60 * 60, maximumHistoryCount: Int = Int.max,
                notificationRetention: TimeInterval = 90 * 24 * 60 * 60, maximumNotificationRecords: Int = 500) {
        self.notificationFreshness = max(0, notificationFreshness)
        self.historyRetention = max(0, historyRetention)
        self.maximumHistoryCount = max(0, maximumHistoryCount)
        self.notificationRetention = max(0, notificationRetention)
        self.maximumNotificationRecords = max(0, maximumNotificationRecords)
    }

    public func isFresh(_ item: ResetNewsItem, now: Date) -> Bool {
        // Discovery time is never substituted for a missing publication date.
        guard item.status == .active, item.facts.contains(where: { $0.confidence == .explicit }), let date = item.publishedAt else { return false }
        let age = now.timeIntervalSince(date)
        return age >= 0 && age <= notificationFreshness
    }

    public func isRecoveryEligible(_ item: ResetNewsItem, now: Date) -> Bool {
        ResetForecastPolicy().retaining(item, now: now)?.facts.contains { $0.confidence == .explicit } == true
    }

    public func applyingExpiration(to item: ResetNewsItem, now: Date) -> ResetNewsItem {
        if let retained = ResetForecastPolicy().retaining(item, now: now) { return retained }
        var expired = item
        if expired.status == .active { expired.status = .expired }
        return expired
    }
}

public struct ResetNewsReduction: Codable, Equatable, Sendable {
    public var state: ResetNewsState
    public var notificationCandidates: [ResetNewsItem]
    public var recoveryCandidates: [ResetNewsItem]
}

/// A successful source refresh is one atomic reduction. Failed fetches must not invoke this to establish a baseline.
public struct ResetNewsReducer: Sendable {
    public var policy: ResetNewsRetentionPolicy
    public var forecastPolicy: ResetForecastPolicy
    public init(policy: ResetNewsRetentionPolicy = .init(), forecastPolicy: ResetForecastPolicy = .init()) {
        self.policy = policy; self.forecastPolicy = forecastPolicy
    }

    public func reduce(previous: ResetNewsState, incoming: [ResetNewsSourceItem], now: Date) -> ResetNewsReduction {
        let grouped = Dictionary(grouping: incoming, by: \.stableID)
        var items: [String: ResetNewsItem] = [:]
        var retired: [String: ResetForecastRetirement] = [:]
        for entry in previous.retiredForecasts ?? [] where entry.retainUntil > now { retired[entry.id] = entry }
        for item in previous.items {
            if let retained = forecastPolicy.retaining(item, now: now) { items[item.id] = retained }
            else if forecastPolicy.isConfirmedTerminal(item) { retire(item, now: now, into: &retired) }
        }
        var records: [String: ResetNewsNotificationRecord] = [:]
        for record in previous.notificationRecords where now.timeIntervalSince(record.recordedAt) <= policy.notificationRetention {
            records[record.key] = record
        }
        var notifications: [ResetNewsItem] = []
        var recovery: [ResetNewsItem] = []
        for id in grouped.keys.sorted() {
            let old = items[id]
            guard let sourceItems = grouped[id], var candidate = refreshed(old: old, id: id, incoming: sourceItems, now: now) else { continue }
            if let retirement = retired[id], (candidate.updatedAt ?? candidate.publishedAt ?? .distantPast) <= retirement.versionAt { continue }
            guard let forecast = forecastPolicy.retaining(candidate, now: now) else {
                if forecastPolicy.isConfirmedTerminal(candidate) { retire(candidate, now: now, into: &retired) }
                items.removeValue(forKey: id)
                continue
            }
            candidate = forecast
            if let retirement = retired.removeValue(forKey: id) { candidate.materialRevision = retirement.revision + 1 }
            if let old {
                candidate.firstSeenAt = old.firstSeenAt
                candidate.publishedAt = candidate.publishedAt ?? old.publishedAt
                candidate.sources = Array(Set(old.sources + candidate.sources)).sorted { $0.rawValue < $1.rawValue }
                candidate.sourceURL = candidate.sourceURL ?? old.sourceURL
                candidate.materialRevision = old.materialRevision + (old.materialKey == candidate.materialKey ? 0 : 1)
            }
            let changed = old == nil || old?.materialRevision != candidate.materialRevision
            let key = candidate.notificationKey
            if records[key] == nil {
                if previous.hasBaseline && changed {
                    if policy.isFresh(candidate, now: now) { notifications.append(candidate) }
                    else if candidate.facts.contains(where: { $0.confidence == .explicit }) { recovery.append(candidate) }
                }
                // Consumption happens even when delivery is disabled: toggling notifications must not replay old news.
                records[key] = ResetNewsNotificationRecord(key: key, recordedAt: now)
            }
            items[id] = candidate
        }
        let retained = forecastPolicy.retaining(Array(items.values), now: now, maximumCount: policy.maximumHistoryCount)
        let ledger = records.values.sorted {
            if $0.recordedAt == $1.recordedAt { return $0.key < $1.key }
            return $0.recordedAt > $1.recordedAt
        }
        let state = ResetNewsState(items: Array(retained.prefix(policy.maximumHistoryCount)),
                                   notificationRecords: Array(ledger.prefix(policy.maximumNotificationRecords)), hasBaseline: true,
                                   retiredForecasts: retired.values.sorted { $0.id < $1.id })
        let retainedIDs = Set(retained.map(\.id))
        return ResetNewsReduction(state: state,
            notificationCandidates: forecastPolicy.retaining(notifications.filter { retainedIDs.contains($0.id) }, now: now),
            recoveryCandidates: forecastPolicy.retaining(recovery.filter { retainedIDs.contains($0.id) }, now: now))
    }

    private func retire(_ item: ResetNewsItem, now: Date, into retired: inout [String: ResetForecastRetirement]) {
        var entry = forecastPolicy.retirement(for: item, now: now)
        if let old = retired[item.id] {
            entry.versionAt = max(entry.versionAt, old.versionAt)
            entry.retainUntil = max(entry.retainUntil, old.retainUntil)
            entry.revision = max(entry.revision, old.revision)
        }
        retired[item.id] = entry
    }

    private func refreshed(old: ResetNewsItem?, id: String, incoming: [ResetNewsSourceItem], now: Date) -> ResetNewsItem? {
        var snapshots: [ResetNewsSource: ResetNewsSourceSnapshot] = [:]
        if let old {
            if let stored = old.sourceSnapshots {
                for snapshot in stored { snapshots[snapshot.source] = snapshot }
            } else {
                // The old cache cannot attribute individual facts. Retain them until each recorded source supplies its own copy.
                for source in old.sources {
                    snapshots[source] = ResetNewsSourceSnapshot(item: old, source: source, statusWasExplicit: old.status != .active)
                }
            }
        }
        let latestKnownVersion = snapshots.values.map(\.versionAt).max() ?? .distantPast
        let engine = ResetNewsRuleEngine()
        for (source, records) in Dictionary(grouping: incoming, by: \.source) {
            let evaluated = records.compactMap { record -> ResetNewsItem? in
                guard var item = engine.evaluate(record, now: now) else { return nil }
                if forecastPolicy.isConfirmedTerminal(item), item.status == .active { item.status = .expired }
                return item
            }
            guard var item = merged(evaluated) else { continue }
            // A completed reset supersedes a prior plan; do not supplement it from an older endpoint.
            if forecastPolicy.isConfirmedTerminal(item) { item.status = item.status == .active ? .expired : item.status }
            let incomingSnapshot = ResetNewsSourceSnapshot(item: item, source: source,
                                                           statusWasExplicit: item.status != .active || records.contains { $0.status != nil })
            // Missing or older source metadata cannot supersede a newer accepted copy from either endpoint.
            guard incomingSnapshot.versionAt >= latestKnownVersion else { continue }
            if incomingSnapshot.status == .active, !incomingSnapshot.statusWasExplicit,
               snapshots.values.contains(where: { $0.status != .active && $0.versionAt >= incomingSnapshot.versionAt }) { continue }
            snapshots[source] = incomingSnapshot
        }
        guard var candidate = merged(snapshots.values.map { $0.item(id: id, firstSeenAt: old?.firstSeenAt ?? now) }) else { return nil }
        candidate.sourceSnapshots = snapshots.values.sorted { $0.source.rawValue < $1.source.rawValue }
        return candidate
    }

    private func merged(_ versions: [ResetNewsItem]) -> ResetNewsItem? {
        let sorted = versions.sorted { lhs, rhs in
            let leftDate = lhs.updatedAt ?? lhs.publishedAt ?? .distantPast
            let rightDate = rhs.updatedAt ?? rhs.publishedAt ?? .distantPast
            if leftDate != rightDate { return leftDate > rightDate }
            if lhs.status != rhs.status { return statusPriority(lhs.status) > statusPriority(rhs.status) }
            if lhs.sources.contains(.timeline) != rhs.sources.contains(.timeline) { return lhs.sources.contains(.timeline) }
            return lhs.originalText.count > rhs.originalText.count
        }
        guard var merged = sorted.first else { return nil }
        var kinds = Set(merged.facts.map(\.kind))
        for version in sorted.dropFirst() {
            for kind in version.facts.map(\.kind) where !kinds.contains(kind) {
                merged.facts.append(contentsOf: version.facts.filter { $0.kind == kind })
                kinds.insert(kind)
            }
            merged.publishedAt = merged.publishedAt ?? version.publishedAt
            merged.sourceURL = merged.sourceURL ?? version.sourceURL
        }
        merged.sources = Array(Set(versions.flatMap(\.sources))).sorted { $0.rawValue < $1.rawValue }
        return merged
    }

    private func statusPriority(_ status: ResetNewsStatus) -> Int {
        switch status {
        case .active: return 0
        case .expired: return 1
        case .superseded: return 2
        case .cancelled: return 3
        }
    }

    private func newestFirst(_ lhs: ResetNewsItem, _ rhs: ResetNewsItem) -> Bool {
        let left = lhs.publishedAt ?? lhs.firstSeenAt, right = rhs.publishedAt ?? rhs.firstSeenAt
        return left == right ? lhs.id < rhs.id : left > right
    }
}
