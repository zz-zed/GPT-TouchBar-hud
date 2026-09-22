import Foundation

public struct ResetNewsRuleEngine: Sendable {
    public init() {}

    public func evaluate(_ source: ResetNewsSourceItem, now: Date) -> ResetNewsItem? {
        let text = [source.title, source.body].compactMap { $0 }.joined(separator: "\n")
        if source.structuredFacts?.isEmpty == true { return nil }
        guard source.structuredFacts != nil || ResetNewsText.matches(#"\bcodex\b"#, in: text) else { return nil }
        let fragments = text.replacingOccurrences(
            of: #"(?:[!?;。！？；\n]+|\.(?=\s|$)|\s+\b(?:but|however)\b\s+|\s+and\s+(?=(?:we\b|will\b|all\b|plus\b|pro\b|(?:gave|given|added|granted|provided)\b)))"#,
            with: "\n", options: [.regularExpression, .caseInsensitive]
        ).components(separatedBy: "\n")
        var facts: [ResetNewsFact] = fillingMissingForecastTiming(source.structuredFacts ?? [], text: text)
        if let weekday = ResetForecastPolicy.scheduledWeekday(in: text),
           !facts.contains(where: { $0.kind == .upcomingReset }),
           !facts.contains(where: { $0.kind == .resetAnnouncement && $0.confidence == .explicit }) {
            facts.removeAll { $0.kind == .resetAnnouncement }
            facts.append(ResetNewsFact(kind: .upcomingReset, scope: audience(in: text), timingText: weekday,
                                       confidence: .tentative, evidence: text))
        }
        let structuredKinds = Set(facts.map(\.kind))
        var cancelled = false
        for rawFragment in fragments {
            let fragment = rawFragment.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !fragment.isEmpty else { continue }
            let hasReset = ResetNewsText.matches(#"\bresets?\b|\bresetting\b|重置|重设"#, in: fragment)
            guard hasReset else { continue }
            if ResetNewsText.matches(#"\b(?:password|configuration|settings|cache|git|repository|api key)\b|密码|配置|缓存"#, in: fragment) { continue }
            let credits = ResetNewsText.matches(#"\breset\s+credits?\b|\b(?:extra|additional|bonus)\s+(?:\d+\s+)?(?:banked\s+)?resets?\b|\b\d+\s+(?:extra|additional|bonus)\s+resets?\b|额外.{0,8}(?:重置|重设)|(?:重置|重设)次数"#, in: fragment)
            let quota = ResetNewsText.matches(#"\blimits?\b|\bquotas?\b|\b(?:weekly|daily|usage)\s+(?:cap|allowance|limit)|额度|限额|用量上限"#, in: fragment)
            guard credits || quota else { continue }
            if ResetNewsText.matches(#"\bcancel(?:led|ed)\b|\bwithdrawn\b|取消|撤销"#, in: fragment) {
                cancelled = true
            } else if isNegatedOrSpeculative(fragment) {
                continue
            }
            let scope = audience(in: fragment) ?? source.title.flatMap(audience)
            let timing = timingDetails(fragment)
            let grantsCredits = ResetNewsText.matches(#"\b(?:extra|additional|bonus|more|giv(?:e|en|ing)|grant(?:ed|ing)?|provid(?:e|ed|ing)|announced|added|receive|get(?:ting|s)?)\b|额外|赠送|增加"#, in: fragment)
            if credits && grantsCredits && !structuredKinds.contains(.extraResetCredits) {
                facts.append(ResetNewsFact(kind: .extraResetCredits, scope: scope, count: creditCount(fragment),
                                           expiresAt: timing.expiry, validityText: timing.validity, evidence: fragment))
            }
            // A credit is an entitlement to request a reset, never evidence that a quota was reset.
            let withoutCredits = fragment.replacingOccurrences(of: #"\breset\s+credits?\b"#, with: "credits", options: [.regularExpression, .caseInsensitive])
            if quota && ResetNewsText.matches(#"\breset(?:s|ting)?\b|重置|重设"#, in: withoutCredits) && (!credits || hasIndependentQuotaReset(withoutCredits)) {
                let upcoming = ResetNewsText.matches(#"\bwill\b|\bscheduled\b|\bgoing to\b|\bplan(?:ned)?\b|\btomorrow\b|\btonight\b|\blater today\b|\bnext\s+(?:week|monday|tuesday|wednesday|thursday|friday|saturday|sunday)\b|预计|将于|即将|计划|明天|今晚"#, in: fragment)
                guard upcoming || hasAnnouncedReset(fragment) || cancelled else { continue }
                let kind: ResetNewsFactKind = upcoming ? .upcomingReset : .resetAnnouncement
                if structuredKinds.contains(kind) { continue }
                facts.append(ResetNewsFact(kind: kind,
                                           scope: scope, effectiveAt: timing.effective,
                                           effectiveAtPrecision: timing.effective == nil ? nil : .exact, timingText: timing.text,
                                           evidence: fragment))
            }
        }
        var seen: Set<String> = []
        facts = facts.filter { seen.insert($0.materialKey).inserted }
        guard !facts.isEmpty else { return nil }
        return ResetNewsItem(id: source.stableID, sources: [source.source], sourceURL: source.url,
                             originalText: text, facts: facts, status: source.status ?? (cancelled ? .cancelled : .active),
                             publishedAt: source.publishedAt, firstSeenAt: now, updatedAt: source.updatedAt)
    }

    func isNegatedOrSpeculative(_ text: String) -> Bool {
        ResetNewsText.matches(#"\b(?:not|never|no|won't|won’t|cannot|can't|can’t|don't|don’t|doesn't|doesn’t|didn't|didn’t)\b.{0,55}\b(?:reset|extra|additional|bonus)\b|\b(?:may|might|could|if|wish|hope|rumou?r|unconfirmed)\b|\bhow to\b|\byou can\b|^reset your\b|没有|不会|不再|并未|无需|无需重置|可能|如果|传闻|希望"#, in: text)
    }

    func fillingMissingForecastTiming(_ facts: [ResetNewsFact], text: String) -> [ResetNewsFact] {
        facts.map { fact in
            guard fact.kind == .upcomingReset, fact.effectiveAt == nil, fact.timingText == nil else { return fact }
            var resolved = fact
            let timing = timingDetails(text)
            resolved.effectiveAt = timing.effective
            resolved.effectiveAtPrecision = timing.effective == nil ? nil : .exact
            resolved.timingText = timing.text ?? ResetForecastPolicy.scheduledWeekday(in: text)
            return resolved
        }
    }

    private func hasAnnouncedReset(_ text: String) -> Bool {
        ResetNewsText.matches(#"\b(?:we|we've|we’ve|have|has|had|just|already|now|are|were|is|was)\b.{0,65}\breset\b|\breset\b.{0,30}\b(?:limits?|quotas?)\b|已.{0,8}重置|重置.{0,10}(?:额度|限额)|(?:额度|限额).{0,8}重置"#, in: text)
    }

    private func hasIndependentQuotaReset(_ text: String) -> Bool {
        ResetNewsText.matches(#"(?:limits?|quotas?|额度|限额).{0,30}(?:reset|重置)|(?:reset|重置).{0,30}(?:limits?|quotas?|额度|限额)"#, in: text)
    }

    func audience(in text: String) -> String? {
        if ResetNewsText.matches(#"\b(?:all|every)\s+(?:codex\s+)?(?:users?|accounts?|plans?|customers?)\b|\beveryone\b|所有用户|全部用户|全体用户"#, in: text) { return "all" }
        let plans = ["free", "plus", "pro", "team", "business", "enterprise", "edu"].filter {
            ResetNewsText.matches("\\b\($0)\\b", in: text)
        }
        return plans.isEmpty ? nil : plans.sorted().joined(separator: ",")
    }

    func creditCount(_ text: String) -> Int? {
        // Ranges are not a single count. Do not silently turn "2–3" into "3".
        if ResetNewsText.matches(#"\d+\s*(?:-|–|—|to|至|\.)\s*\d+\s+(?:(?:extra|additional|bonus|banked)\s+)*resets?\b|\b(?:every|each|per)\s+day\b|每天|每日"#, in: text) { return nil }
        let pattern = #"\b(\d+|one|two|three|four|five|six|seven|eight|nine|ten|a|an)\s+(?:(?:extra|additional|bonus|more|codex|banked)\s+){0,3}resets?(?:\s+credits?)?\b"#
        let value = ResetNewsText.capture(pattern, in: text)
            ?? ResetNewsText.capture(#"(?:额外|增加|赠送)?\s*(\d+)\s*次.{0,4}(?:重置|重设)"#, in: text)
        guard let value else { return nil }
        if let count = Int(value), count >= 0 { return count }
        return ["a": 1, "an": 1, "one": 1, "two": 2, "three": 3, "four": 4, "five": 5,
                "six": 6, "seven": 7, "eight": 8, "nine": 9, "ten": 10][value.lowercased()]
    }

    func timingDetails(_ text: String) -> (effective: Date?, text: String?, expiry: Date?, validity: String?) {
        let timestamp = #"\d{4}-\d{2}-\d{2}T\d{2}:\d{2}(?::\d{2}(?:\.\d+)?)?(?:Z|[+-]\d{2}:?\d{2})"#
        let expiryText = ResetNewsText.capture("(?:until|expires?(?: on| at)?|valid through|有效期至|截至)\\s+(\(timestamp)|[^,;。\\n]+)", in: text)
        let expiry = expiryText.flatMap(ResetNewsDate.parse)
        let dateText = ResetNewsText.capture("(?:at|on|于)\\s+(\(timestamp))", in: text)
        let effective = dateText == expiryText ? nil : dateText.flatMap(ResetNewsDate.parse)
        let relative = ResetNewsText.capture(#"\b(tomorrow|tonight|later today|today|next\s+(?:week|monday|tuesday|wednesday|thursday|friday|saturday|sunday)|\d{4}-\d{2}-\d{2}(?:\s+\d{1,2}:\d{2}(?:\s*(?:UTC|PT|PDT|PST|ET))?)?)\b|(明天|今晚|今天)"#, in: text)
            ?? ResetNewsText.capture(#"(明天|今晚|今天)"#, in: text)
        return (effective, effective != nil ? nil : relative, expiry, expiryText)
    }
}

public enum ResetNewsSummary {
    public static func chinese(_ item: ResetNewsItem, now: Date = Date(), calendar: Calendar = .current) -> String {
        let descriptions = item.facts.map { fact -> String in
            let main: String
            switch fact.kind {
            case .upcomingReset: main = "预计重置 Codex 额度"
            case .resetAnnouncement: main = "公告称已重置 Codex 额度"
            case .extraResetCredits:
                main = fact.count.map { "额外提供 \($0) 次 Codex 重置机会" } ?? "提供额外 Codex 重置机会（次数未说明）"
            }
            var details = [fact.scope.map(scopeLabel) ?? "适用范围未说明"]
            if fact.kind == .upcomingReset {
                let date = ResetForecastDatePresentation(fact: fact, publishedAt: item.publishedAt, now: now, calendar: calendar)
                details.append("预计重置日期：\(date.dateText)")
                details.append(date.timeText)
                if let basis = date.basisText { details.append(basis) }
            } else if let date = fact.effectiveAt { details.append("安排时间：\(dateLabel(date))") }
            else if let text = fact.timingText { details.append("时间：\(relativeLabel(text))") }
            if let date = fact.expiresAt, fact.kind == .upcomingReset {
                let expiry = ResetForecastDatePresentation(fact: .init(kind: .upcomingReset, effectiveAt: date, effectiveAtPrecision: .exact),
                    publishedAt: nil, now: now, calendar: calendar)
                details.append("有效期至 \(expiry.dateText) \(expiry.timeText)")
            } else if let date = fact.expiresAt { details.append("有效期至 \(dateLabel(date))") }
            else if let text = fact.validityText { details.append("有效期：\(relativeLabel(text))") }
            return (fact.confidence == .tentative ? "待确认：" : "") + main + "（" + details.joined(separator: "；") + "）"
        }
        let prefix: String
        switch item.status {
        case .active: prefix = ""
        case .cancelled: prefix = "已取消："
        case .expired: prefix = "已过期："
        case .superseded: prefix = "已被后续消息取代："
        }
        return prefix + descriptions.joined(separator: "；")
    }

    private static func scopeLabel(_ scope: String) -> String {
        if scope == "all" { return "所有用户" }
        let labels = ["free": "Free", "plus": "Plus", "pro": "Pro", "team": "Team", "business": "Business", "enterprise": "Enterprise", "edu": "Edu", "codex": "Codex", "chatgpt_work": "ChatGPT Work"]
        return scope.components(separatedBy: ",").map { labels[$0] ?? $0 }.joined(separator: "、") + " 用户"
    }

    private static func relativeLabel(_ text: String) -> String {
        ["tomorrow": "明天（相对公告发布时间）", "tonight": "今晚（相对公告发布时间）",
         "today": "当天（相对公告发布时间）", "later today": "当天稍后（相对公告发布时间）",
         "next week": "下周（相对公告发布时间）", "within an hour": "一小时内（相对公告发布时间）",
         "within 30 minutes": "30 分钟内（相对公告发布时间）"][text.lowercased()] ?? text
    }

    private static func dateLabel(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        return formatter.string(from: date)
    }
}
