import Foundation

public struct ResetNewsRuleEngine: Sendable {
    public init() {}

    public func evaluate(_ source: ResetNewsSourceItem, now: Date) -> ResetNewsItem? {
        let text = [source.title, source.body].compactMap { $0 }.joined(separator: "\n")
        if source.structuredFacts?.isEmpty == true { return nil }
        let paidChatGPTReset = audience(in: text) == "paid_chatgpt" && upcomingResetEvidence(in: text) != nil
        guard source.structuredFacts != nil || ResetNewsText.matches(#"\bcodex\b|\bchatgpt\s+work\b"#, in: text)
                || paidChatGPTReset else { return nil }
        let fragments = resetClauses(in: text)
        var facts: [ResetNewsFact] = fillingMissingForecastTiming(source.structuredFacts ?? [], text: text)
        let actions = resetFactEvidence(in: text)
        if !facts.contains(where: { $0.kind == .upcomingReset }),
           actions.contains(where: { $0.kind == .upcomingReset && ResetForecastPolicy.scheduledWeekday(in: $0.evidence) != nil }) {
            facts.removeAll { $0.kind == .resetAnnouncement && $0.confidence == .tentative }
        }
        let structuredKinds = Set(facts.map(\.kind))
        for action in actions where !structuredKinds.contains(action.kind) {
            let timing = timingDetails(action.evidence)
            let weekday = ResetForecastPolicy.scheduledWeekday(in: action.evidence)
            facts.append(ResetNewsFact(kind: action.kind, scope: audience(in: action.evidence),
                effectiveAt: timing.effective, effectiveAtPrecision: timing.effective == nil ? nil : .exact,
                timingText: timing.text ?? weekday,
                confidence: weekday == nil ? .explicit : .tentative, evidence: action.evidence))
        }
        for rawFragment in fragments {
            let fragment = rawFragment.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !fragment.isEmpty else { continue }
            let hasReset = ResetNewsText.matches(#"\bresets?\b|\bresetting\b|重置|重设"#, in: fragment)
            guard hasReset else { continue }
            if ResetNewsText.matches(#"\b(?:password|configuration|settings|cache|git|repository|api key)\b|密码|配置|缓存"#, in: fragment) { continue }
            let credits = ResetNewsText.matches(#"\breset\s+credits?\b|\b(?:extra|additional|bonus)\s+(?:\d+\s+)?(?:banked\s+)?resets?\b|\b\d+\s+(?:extra|additional|bonus)\s+resets?\b|额外.{0,8}(?:重置|重设)|(?:重置|重设)次数"#, in: fragment)
            guard credits, !isNegatedOrSpeculative(fragment) else { continue }
            let scope = audience(in: fragment) ?? source.title.flatMap(audience)
            let timing = timingDetails(fragment)
            let grantsCredits = ResetNewsText.matches(#"\b(?:extra|additional|bonus|more|giv(?:e|en|ing)|grant(?:ed|ing)?|provid(?:e|ed|ing)|announced|added|receive|get(?:ting|s)?)\b|额外|赠送|增加"#, in: fragment)
            if credits && grantsCredits && !structuredKinds.contains(.extraResetCredits) {
                facts.append(ResetNewsFact(kind: .extraResetCredits, scope: scope, count: creditCount(fragment),
                                           expiresAt: timing.expiry, validityText: timing.validity, evidence: fragment))
            }
        }
        var seen: Set<String> = []
        facts = facts.filter { seen.insert($0.materialKey).inserted }
        guard !facts.isEmpty else { return nil }
        let cancelled = lastResetActionIsTerminal(in: text)
            && ResetNewsText.matches(#"\bcancel(?:led|ed)\b|\bwithdrawn\b|取消|撤销"#, in: text)
        return ResetNewsItem(id: source.stableID, sources: [source.source], sourceURL: source.url,
                             originalText: text, facts: facts, status: source.status ?? (cancelled ? .cancelled : .active),
                             publishedAt: source.publishedAt, firstSeenAt: now, updatedAt: source.updatedAt)
    }

    func isNegatedOrSpeculative(_ text: String) -> Bool {
        isSpeculativeResetClause(text) || ResetNewsText.matches(#"\b(?:not|never|no|won't|won’t|cannot|can't|can’t|don't|don’t|doesn't|doesn’t|didn't|didn’t)\b.{0,55}\b(?:reset|extra|additional|bonus)\b|\b(?:resets?|resetting)\b.{0,25}\b(?:not|never|isn't|isn’t|aren't|aren’t|won't|won’t|no longer)\b.{0,25}\b(?:happen(?:ing)?|coming|landing|scheduled|planned|arriving|available|provided|confirmed)\b|没有|不会|不再|并未|无需|无需重置"#, in: text)
    }

    private func isSpeculativeResetClause(_ text: String) -> Bool {
        ResetNewsText.matches(#"\b(?:may|might|could|would|should|if|wish|hope|rumou?r|unconfirmed|unlikely|uncertain|possibly|perhaps|maybe|considering|discussing|whether)\b|\bhow to\b|\byou can\b|^\s*reset your\b|[?？]|可能|如果|传闻|希望|不确定"#, in: text)
    }

    /// Interpret independent quota actions; a future model release or credit grant
    /// must never turn an earlier completed reset into a future quota reset.
    func resetFactEvidence(in text: String) -> [(kind: ResetNewsFactKind, evidence: String)] {
        resetClauses(in: text).compactMap { rawClause in
            let clause = rawClause.trimmingCharacters(in: .whitespacesAndNewlines)
            guard ResetNewsText.matches(#"\bresets?\b|\bresetting\b|重置|重设"#, in: clause),
                  !ResetNewsText.matches(#"\b(?:password|router|laptop|configuration|settings|cache|git|repository|api key)\b|密码|配置|缓存"#, in: clause),
                  !isNegatedOrSpeculative(clause) else { return nil }
            let terminal = ResetForecastPolicy.hasTerminalResetText(clause)
                && (quotaResetText(clause) == clause || hasIndependentQuotaReset(clause))
            let quotaAction = hasIndependentQuotaReset(clause)
                || ResetForecastPolicy.scheduledWeekday(in: clause) != nil
            guard quotaAction || terminal else { return nil }
            // Past quota actions stay completed even when another product has a future date.
            if terminal || hasCompletedResetAction(clause) {
                return (.resetAnnouncement, clause)
            }
            let future = ResetNewsText.matches(#"\b(?:resets?|resetting)\b.{0,55}\b(?:will|scheduled|landing|arriving|coming|tomorrow|tonight|later today|within|next\s+(?:week|monday|tuesday|wednesday|thursday|friday|saturday|sunday))\b|\b(?:will|going to|plan(?:ned)?|promised)\b.{0,55}\b(?:resets?|resetting)\b|(?:将于|即将|计划|明天|今晚).{0,25}(?:重置|重设)|(?:重置|重设).{0,25}(?:明天|今晚|将于|即将)"#, in: clause)
            if future {
                return (.upcomingReset, clause)
            }
            if hasAnnouncedReset(clause) {
                return (.resetAnnouncement, clause)
            }
            return nil
        }
    }

    func upcomingResetEvidence(in text: String) -> String? {
        resetFactEvidence(in: text).first { $0.kind == .upcomingReset }?.evidence
    }

    /// An explicit withdrawal can retire a previous plan without itself claiming a completed reset.
    /// Reading in order permits a later independent promise to replace an earlier cancellation.
    func lastResetActionIsTerminal(in text: String) -> Bool {
        var terminal = false
        for rawClause in resetClauses(in: text) {
            let clause = rawClause.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !isSpeculativeResetClause(clause) else { continue }
            if ResetForecastPolicy.hasTerminalResetText(clause),
               quotaResetText(clause) == clause || hasIndependentQuotaReset(clause) {
                terminal = true
            } else if let action = resetFactEvidence(in: clause).last {
                if action.kind == .upcomingReset { terminal = false }
                else if hasCompletedResetAction(clause) { terminal = true }
            }
        }
        return terminal
    }

    private func resetClauses(in text: String) -> [String] {
        // Keep question punctuation as evidence, and keep plan lists such as Plus and Pro together.
        let sentences = text.replacingOccurrences(of: #"([?？])"#, with: "$1\n", options: .regularExpression)
        return sentences.replacingOccurrences(
            of: #"(?:[!;。！；\n]+|\.(?=\s|$)|\s+\b(?:but|however)\b\s+|\s+and\s+(?=(?:(?:we|they|i)\s+(?:will|have|had|reset|give|gave|grant|granted)|will\b|(?:reset|gave|given|added|granted|provided)\b|(?:codex|chatgpt(?:\s+work)?)\s+(?:limits?|quotas?)\b|(?:(?:all|the)\s+)?(?:limits?|quotas?)\s+(?:will|reset|have|are)\b|(?:plus|pro|team|business|enterprise|edu)\s+(?:users?|accounts?)\s+(?:will|get|receive)\b|(?:a|the|our|new)\s+(?:new\s+)?(?:model|feature|release|version)\b)))"#,
            with: "\n", options: [.regularExpression, .caseInsensitive]
        ).components(separatedBy: "\n")
    }

    func fillingMissingForecastTiming(_ facts: [ResetNewsFact], text: String) -> [ResetNewsFact] {
        facts.map { fact in
            guard fact.kind == .upcomingReset, fact.effectiveAt == nil, fact.timingText == nil else { return fact }
            var resolved = fact
            let timing = timingDetails(fact.evidence.isEmpty ? text : fact.evidence)
            resolved.effectiveAt = timing.effective
            resolved.effectiveAtPrecision = timing.effective == nil ? nil : .exact
            resolved.timingText = timing.text ?? ResetForecastPolicy.scheduledWeekday(in: text)
            return resolved
        }
    }

    private func hasAnnouncedReset(_ text: String) -> Bool {
        ResetNewsText.matches(#"\b(?:we|we've|we’ve|have|has|had|just|already|now|are|were|is|was)\b.{0,65}\breset\b|\breset\b.{0,30}\b(?:limits?|quotas?)\b|已.{0,8}重置|重置.{0,10}(?:额度|限额)|(?:额度|限额).{0,8}重置"#, in: text)
    }

    func hasIndependentQuotaReset(_ text: String) -> Bool {
        // Remove entitlements before looking for a quota action. Nearby quota wording alone
        // does not turn receiving a banked reset into resetting that quota.
        let withoutCredits = quotaResetText(text)
        guard !ResetNewsText.matches(#"\breset\s+(?:animation|button|screen|menu|form|workflow|feature|counter)\b"#, in: withoutCredits) else { return false }
        return ResetNewsText.matches(#"\b(?:limits?|quotas?)\b.{0,40}\breset(?:s|ting)?\b|\breset(?:s|ting)?\b(?:\s+(?:the|all|our|your|their|codex|usage|weekly|daily|rate)){0,5}\s+(?:limits?|quotas?|caps?|allowance)\b|\b(?:global|full|usage|codex)\s+resets?\b|(?:额度|限额).{0,25}(?:重置|重设)|(?:重置|重设).{0,25}(?:额度|限额)"#, in: withoutCredits)
    }

    private func quotaResetText(_ text: String) -> String {
        text.replacingOccurrences(
            of: #"\breset\s+credits?\b|\b(?:(?:\d+|one|two|three|a|an|another)\s+)?(?:(?:extra|additional|bonus|banked)\s+)+resets?\b|额外.{0,8}(?:重置|重设)|(?:重置|重设)次数"#,
            with: "credits", options: [.regularExpression, .caseInsensitive])
    }

    private func hasCompletedResetAction(_ text: String) -> Bool {
        ResetNewsText.matches(#"\b(?:we|they|i)\s+(?:(?:have|had)\s+)?(?:(?:just|already|now)\s+)?reset\b|(?<!will )\b(?:have|has|had|just|already)\s+(?:been\s+)?reset\b|\bresets?\b.{0,40}\b(?:yesterday|last\s+(?:night|week|Monday|Tuesday|Wednesday|Thursday|Friday|Saturday|Sunday))\b|\bresets?\s+(?:(?:has|have)\s+been\s+|was\s+)?(?:already\s+)?(?:applied|propagated)\b|已.{0,8}(?:重置|重设)|(?:重置|重设)已完成"#, in: text)
    }

    func audience(in text: String) -> String? {
        if ResetNewsText.matches(#"\b(?:all|every)\s+paid\s+chatgpt\s+(?:users?|accounts?|subscriptions?)\b|所有付费\s*ChatGPT"#, in: text) { return "paid_chatgpt" }
        if ResetNewsText.matches(#"\b(?:all|every)\s+paid\s+(?:users?|accounts?|plans?|customers?|subscriptions?)\b|所有付费用户|所有付费账号"#, in: text) { return "paid" }
        let planName = #"(?:free|plus|pro|team|business|enterprise|edu)"#
        let plans = ["free", "plus", "pro", "team", "business", "enterprise", "edu"].filter {
            let after = "\\b\($0)\\b(?:(?:\\s*(?:,|/|&)\\s*|\\s+and\\s+)\(planName))*(?:\\s+\\$\\d+(?:\\.\\d+)?)?\\s+(?:(?:codex|chatgpt(?:\\s+work)?)\\s+)?(?:users?|accounts?|plans?|subscribers?|subscriptions?|tiers?|customers?)\\b"
            let eligibility = "\\b(?:for|to|on|every|each)\\s+(?:all\\s+)?(?:\(planName)(?:\\s*(?:,|/|&)\\s*|\\s+and\\s+))*\($0)\\b(?:(?:\\s*(?:,|/|&)\\s*|\\s+and\\s+)\(planName))*(?=\\s*(?:$|[,.!?;…]|(?:users?|accounts?|plans?|subscribers?|subscriptions?|tiers?|customers?)\\b))"
            return ResetNewsText.matches(after, in: text) || ResetNewsText.matches(eligibility, in: text)
        }
        if !plans.isEmpty { return plans.sorted().joined(separator: ",") }
        if ResetNewsText.matches(#"\bpaid\s+chatgpt\s+(?:users?|accounts?|subscriptions?)\b|付费\s*ChatGPT"#, in: text) { return "paid_chatgpt" }
        if ResetNewsText.matches(#"\bpaid\s+(?:users?|accounts?|plans?|customers?|subscriptions?)\b|付费用户|付费账号"#, in: text) { return "paid" }
        if ResetNewsText.matches(#"\b(?:all|every)\s+(?:codex\s+)?(?:users?|accounts?|plans?|customers?)\b|\beveryone\b|所有用户|全部用户|全体用户"#, in: text) { return "all" }
        return nil
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
        let relative = ResetForecastTiming.timingText(in: text)
            ?? ResetNewsText.capture(#"\b(tomorrow|tonight|later today|today|next\s+(?:week|monday|tuesday|wednesday|thursday|friday|saturday|sunday)|\d{4}-\d{2}-\d{2}(?:\s+\d{1,2}:\d{2}(?:\s*(?:UTC|PT|PDT|PST|ET))?)?)\b|(明天|今晚|今天)"#, in: text)
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

    public static func scopeLabel(_ scope: String) -> String {
        if scope == "all" { return "所有用户" }
        if scope == "paid_chatgpt" { return "付费 ChatGPT 用户" }
        if scope == "paid" { return "付费用户" }
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
