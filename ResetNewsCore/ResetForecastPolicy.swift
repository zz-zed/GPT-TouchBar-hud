import Foundation

/// The only display/retention policy: scheduled resets today or later in the local calendar.
/// Relative labels retain their original precision; resolving a day never invents an exact reset time.
public struct ResetForecastPolicy: Sendable {
    public var calendar: Calendar
    public init(calendar: Calendar = .current) { self.calendar = calendar }

    public func scheduledDate(for fact: ResetNewsFact, publishedAt: Date?) -> Date? {
        guard fact.kind == .upcomingReset else { return nil }
        if let date = fact.effectiveAt { return date.timeIntervalSince1970.isFinite ? date : nil }
        guard let text = fact.timingText?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() else { return nil }
        if ResetNewsText.matches(#"^\d{4}-\d{2}-\d{2}$"#, in: text) {
            let fields = text.split(separator: "-").compactMap { Int($0) }
            var gregorian = Calendar(identifier: .gregorian); gregorian.timeZone = calendar.timeZone
            guard fields.count == 3, let date = gregorian.date(from: DateComponents(year: fields[0], month: fields[1], day: fields[2])),
                  gregorian.dateComponents([.year, .month, .day], from: date) == DateComponents(year: fields[0], month: fields[1], day: fields[2]) else { return nil }
            return date
        }
        guard let publishedAt, publishedAt.timeIntervalSince1970.isFinite else { return nil }
        let offset: Int
        switch text {
        case "today", "tonight", "later today", "今天", "今晚": offset = 0
        case "tomorrow", "明天": offset = 1
        default:
            let weekdays = ["sunday", "monday", "tuesday", "wednesday", "thursday", "friday", "saturday"]
            guard let index = weekdays.firstIndex(of: text) else { return nil }
            let weekday = calendar.component(.weekday, from: publishedAt)
            return calendar.date(byAdding: .day, value: (index + 1 - weekday + 7) % 7,
                                 to: calendar.startOfDay(for: publishedAt))
        }
        return calendar.date(byAdding: .day, value: offset, to: calendar.startOfDay(for: publishedAt))
    }

    public func retaining(_ item: ResetNewsItem, now: Date) -> ResetNewsItem? {
        var result = item
        // Older versions automatically marked an exact time expired. Only provenance proving
        // every source is still active permits restoring that item for the remainder of today.
        if result.status == .expired, let snapshots = result.sourceSnapshots, !snapshots.isEmpty,
           snapshots.allSatisfy({ $0.status == .active }) { result.status = .active }
        guard result.status == .active, !Self.hasTerminalResetText(result.originalText) else { return nil }
        result.facts = eligibleFacts(normalizedFacts(result.facts, text: result.originalText), publishedAt: result.publishedAt, now: now)
        guard !result.facts.isEmpty else { return nil }
        result.sourceSnapshots = result.sourceSnapshots?.map { snapshot in
            var cleaned = snapshot
            cleaned.facts = snapshot.status == .active
                ? eligibleFacts(normalizedFacts(snapshot.facts, text: snapshot.originalText), publishedAt: snapshot.publishedAt, now: now) : []
            return cleaned
        }
        return result
    }

    public func retaining(_ items: [ResetNewsItem], now: Date, maximumCount: Int = Int.max) -> [ResetNewsItem] {
        Array(items.compactMap { retaining($0, now: now) }.sorted { lhs, rhs in
            let left = firstDate(lhs) ?? .distantFuture, right = firstDate(rhs) ?? .distantFuture
            return left == right ? lhs.id < rhs.id : left < right
        }.prefix(max(0, maximumCount)))
    }

    public func firstDate(_ item: ResetNewsItem) -> Date? {
        item.facts.compactMap { scheduledDate(for: $0, publishedAt: item.publishedAt) }.min()
    }

    public func retirement(for item: ResetNewsItem, now: Date) -> ResetForecastRetirement {
        let dates = item.facts.compactMap { scheduledDate(for: $0, publishedAt: item.publishedAt) }
            + (item.sourceSnapshots ?? []).flatMap { snapshot in
                snapshot.facts.compactMap { scheduledDate(for: $0, publishedAt: snapshot.publishedAt) }
            }
        let lastDay = dates.max().flatMap { calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: $0)) }
        return ResetForecastRetirement(id: item.id, versionAt: item.updatedAt ?? item.publishedAt ?? .distantPast,
                                       retainUntil: max(now.addingTimeInterval(90 * 86_400), lastDay ?? now), revision: item.materialRevision)
    }

    public func isConfirmedTerminal(_ item: ResetNewsItem) -> Bool {
        if Self.hasTerminalResetText(item.originalText) { return true }
        if item.status != .active {
            if item.status == .expired, let snapshots = item.sourceSnapshots, !snapshots.isEmpty,
               snapshots.allSatisfy({ $0.status == .active }) { return false }
            return true
        }
        return !item.facts.contains { $0.kind == .upcomingReset }
            && item.facts.contains { $0.kind == .resetAnnouncement && $0.confidence == .explicit }
    }

    static func scheduledWeekday(in text: String) -> String? {
        guard !hasTerminalResetText(text) else { return nil }
        return ResetNewsText.capture(#"\b(?:promised\s+(?:a\s+)?reset\s+for|resets?\s+(?:is\s+)?scheduled\s+for)\s+(Monday|Tuesday|Wednesday|Thursday|Friday|Saturday|Sunday)\b"#, in: text)
    }

    static func hasTerminalResetText(_ text: String) -> Bool {
        // Match positive terminal statements, not "will be completed" or "has not yet completed".
        ResetNewsText.matches(#"\breset\s+all\s+propagated\b|\bresets?\s+(?:(?:(?:scheduled\s+)?for\s+(?:Monday|Tuesday|Wednesday|Thursday|Friday|Saturday|Sunday))\s+)?(?:(?:has\s+been|have\s+been|was|is|has|have)\s+)?(?:now\s+|already\s+)?(?:completed|cancelled|canceled|withdrawn)\b|\b(?:we|they)\s+(?:have\s+)?(?:now\s+|already\s+)?(?:completed|cancelled|canceled|withdrawn)\s+(?:the\s+)?(?:Codex\s+)?reset\b|\b(?:will\s+not|won't|won’t)\s+reset\b|重置已完成|重置已取消|取消重置"#, in: text)
    }

    private func normalizedFacts(_ facts: [ResetNewsFact], text: String) -> [ResetNewsFact] {
        let facts = ResetNewsRuleEngine().fillingMissingForecastTiming(facts, text: text)
        guard !facts.contains(where: { $0.kind == .upcomingReset }),
              let weekday = Self.scheduledWeekday(in: text),
              let old = facts.first(where: { $0.kind == .resetAnnouncement && $0.confidence == .tentative }) else { return facts }
        return facts.filter { $0.kind != .resetAnnouncement } + [ResetNewsFact(kind: .upcomingReset,
            scope: old.scope, timingText: weekday, confidence: .tentative, evidence: text)]
    }

    private func eligibleFacts(_ facts: [ResetNewsFact], publishedAt: Date?, now: Date) -> [ResetNewsFact] {
        let today = calendar.startOfDay(for: now)
        return facts.filter { fact in
            guard let date = scheduledDate(for: fact, publishedAt: publishedAt), date >= today else { return false }
            // A source-supplied expiry is authoritative; the planned reset's clock time is not an expiry.
            if let expiry = fact.expiresAt { return expiry.timeIntervalSince1970.isFinite && expiry > now }
            return true
        }.sorted {
            (scheduledDate(for: $0, publishedAt: publishedAt) ?? .distantFuture)
                < (scheduledDate(for: $1, publishedAt: publishedAt) ?? .distantFuture)
        }
    }
}

/// Minimal anti-rollback metadata, not a retained historical card or source body.
public struct ResetForecastRetirement: Codable, Equatable, Sendable {
    public var id: String
    public var versionAt: Date
    public var retainUntil: Date
    public var revision: Int
    public init(id: String, versionAt: Date, retainUntil: Date, revision: Int = 1) {
        self.id = id; self.versionAt = versionAt; self.retainUntil = retainUntil; self.revision = revision
    }
}
