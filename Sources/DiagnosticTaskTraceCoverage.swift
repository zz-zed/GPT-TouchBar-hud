import Foundation

/// Interprets frozen, typed records only. It does not infer task truth or reread rollout files.
struct DiagnosticTaskTraceCoverage: Encodable {
    struct Snapshot: Encodable {
        let reference: DiagnosticTaskSnapshotReference
        let integrity: DiagnosticTaskSnapshotIntegrity
        let predecessorMissing: Bool
        let identityMissing: Bool
        let evidenceComplete: Bool
        let countedMembers: [UUID]?
        let addedCountedMembers: [UUID]?
        let removedCountedMembers: [UUID]?
        let consumption: [DiagnosticTaskConsumption]
        let omittedConsumption: Int
    }
    struct Change: Encodable {
        let context: DiagnosticTaskTraceContext
        let identity: DiagnosticTaskTraceIdentity
        let countedBefore: Bool
        let countedAfter: Bool
        let reason: DiagnosticTaskMemberReason
    }
    struct Read: Encodable {
        let context: DiagnosticTaskTraceContext
        let identity: DiagnosticTaskTraceIdentity
        let metrics: DiagnosticTaskReadMetrics
    }
    struct Lifecycle: Encodable {
        let context: DiagnosticTaskTraceContext
        let identity: DiagnosticTaskTraceIdentity
        let transition: DiagnosticTaskLifecycleTransition
    }
    struct ObservationGap: Encodable {
        let context: DiagnosticTaskTraceContext
        let droppedCount: UInt64
        let reason: DiagnosticTaskObservationGapReason
    }
    let schemaVersion = 1
    let eventCount: Int
    let physicalVisibility = "unknown"
    let crossProcessTaskCorrelation = "unknown"
    let evidenceComplete: Bool
    let globalRecordingGap: Bool
    let deliveryEvidenceIncomplete: Bool
    let observationGaps: [ObservationGap]
    let omittedObservationGaps: Int
    let summaryOmittedSnapshots: Int
    let summaryOmittedChanges: Int
    let summaryOmittedReads: Int
    let summaryOmittedLifecycles: Int
    let snapshots: [Snapshot]
    let memberChanges: [Change]
    let reads: [Read]
    let lifecycles: [Lifecycle]

    static func collect(events: Data, globalRecordingGap: Bool) -> Self {
        let decoder = DiagnosticEventEnvelope.decoder()
        let records = events.split(separator: 10).compactMap { try? decoder.decode(DiagnosticEventEnvelope.self, from: Data($0)) }
        var grouped: [UUID: [DiagnosticTaskTraceEvent]] = [:]
        var references: [UUID: DiagnosticTaskSnapshotReference] = [:]
        var order: [UUID] = []
        var knownTasks: Set<String> = []; var knownTurns: Set<String> = []; var knownFiles: Set<String> = []
        var changes: [Change] = []; var reads: [Read] = []; var observationGaps: [ObservationGap] = []
        var lifecycles: [Lifecycle] = []
        var aliasGap = false
        for record in records {
            guard case .taskTrace(let event) = record.event else { continue }
            let reference: DiagnosticTaskSnapshotReference?
            switch event {
            case .observationGap(let context, let count, let reason):
                observationGaps.append(.init(context: context, droppedCount: count, reason: reason))
                reference = nil
            case .snapshot(let value, _), .snapshotMembers(let value, _, _), .snapshotCheckpoint(let value, _), .consumption(let value, _):
                reference = value
            default: reference = nil
            }
            if let reference {
                if references[reference.snapshotID] == nil { order.append(reference.snapshotID); references[reference.snapshotID] = reference }
                grouped[reference.snapshotID, default: []].append(event)
            }
            switch event {
            case .identity(_, let identity, let continuity):
                let owner = identity.domain.uuidString + identity.taskAlias.uuidString
                knownTasks.insert(owner)
                if let turn = identity.turnAlias { knownTurns.insert(owner + turn.uuidString) }
                if let file = identity.fileGeneration { knownFiles.insert(owner + file.uuidString) }
                if continuity == .capacityReached || continuity == .remappedAfterEviction || continuity == .possibleDiscontinuity { aliasGap = true }
            case .aliasGap: aliasGap = true
            case .member(let context, let identity, let before, let after, let reason):
                changes.append(.init(context: context, identity: identity, countedBefore: before, countedAfter: after, reason: reason))
            case .read(let context, let identity, let metrics): reads.append(.init(context: context, identity: identity, metrics: metrics))
            case .lifecycle(let context, let identity, let transition):
                lifecycles.append(.init(context: context, identity: identity, transition: transition))
            default: break
            }
        }
        var integrity: [UUID: DiagnosticTaskSnapshotIntegrity] = [:]
        var members: [UUID: [DiagnosticTaskSnapshotMember]] = [:]
        for id in order {
            guard let reference = references[id] else { continue }
            let observations = grouped[id] ?? []
            integrity[id] = DiagnosticTaskSnapshotIntegrity.inspect(reference: reference, events: observations)
            members[id] = observations.flatMap { observation -> [DiagnosticTaskSnapshotMember] in
                if case .snapshotMembers(_, _, let page) = observation { return page }; return []
            }
        }
        let gap = globalRecordingGap || aliasGap || observationGaps.contains { $0.reason == .producerBufferLimit }
        let deliveryGap = observationGaps.contains { $0.reason == .deliveryBufferLimit }
        var localComplete: [UUID: Bool] = [:]
        var identityMissingByID: [UUID: Bool] = [:]
        var missingPredecessor: [UUID: Bool] = [:]
        for id in order {
            let reference = references[id]!
            let predecessor = reference.previousSnapshotID.flatMap { references[$0] }
            missingPredecessor[id] = reference.previousSnapshotID != nil && (predecessor == nil || predecessor?.domain != reference.domain
                || predecessor?.monitoringGeneration != reference.monitoringGeneration)
            identityMissingByID[id] = (members[id] ?? []).contains { member in
                let owner = reference.domain.uuidString + member.taskAlias.uuidString
                return !knownTasks.contains(owner) || member.turnAlias.map { !knownTurns.contains(owner + $0.uuidString) } == true
                    || member.fileGeneration.map { !knownFiles.contains(owner + $0.uuidString) } == true
            }
            localComplete[id] = integrity[id]?.complete == true && missingPredecessor[id] == false && identityMissingByID[id] == false && !gap
        }
        var chainComplete: [UUID: Bool] = [:]
        for id in order {
            var cursor: UUID? = id; var chain: [UUID] = []; var seen: Set<UUID> = []; var complete = true
            while let current = cursor {
                if let known = chainComplete[current] { complete = known; break }
                guard localComplete[current] == true, seen.insert(current).inserted else { complete = false; break }
                chain.append(current); cursor = references[current]?.previousSnapshotID
            }
            for item in chain { chainComplete[item] = complete }
            chainComplete[id] = complete
        }
        let snapshots: [Snapshot] = order.compactMap { id in
            guard let reference = references[id], let check = integrity[id] else { return nil }
            let previous = reference.previousSnapshotID
            let predecessorMissing = missingPredecessor[id] ?? true
            let identityMissing = identityMissingByID[id] ?? true
            let complete = chainComplete[id] == true
            let counted = check.complete ? Set((members[id] ?? []).filter(\.counted).map(\.taskAlias)) : nil
            // Compare only verified complete checkpoints; leftovers can never become a full member list.
            let predecessorComplete = previous.flatMap { chainComplete[$0] } == true
            let oldCounted = predecessorComplete ? Set((members[previous!] ?? []).filter(\.counted).map(\.taskAlias)) : nil
            let observations = (grouped[id] ?? []).compactMap { event -> DiagnosticTaskConsumption? in
                if case .consumption(_, let observation) = event { return observation }; return nil
            }
            return Snapshot(reference: reference, integrity: check, predecessorMissing: predecessorMissing,
                identityMissing: identityMissing, evidenceComplete: complete,
                countedMembers: complete ? counted?.sorted { $0.uuidString < $1.uuidString } : nil,
                addedCountedMembers: complete && oldCounted != nil ? counted?.subtracting(oldCounted!).sorted { $0.uuidString < $1.uuidString } : nil,
                removedCountedMembers: complete && oldCounted != nil ? oldCounted?.subtracting(counted ?? []).sorted { $0.uuidString < $1.uuidString } : nil,
                consumption: Array(observations.suffix(16)), omittedConsumption: max(0, observations.count - 16))
        }
        // The raw frozen JSONL retains every acquired record. Only this human-readable index is bounded.
        // Reserve space for failures before filling with recent normal/ignored reads.
        var selectedReads = Set(reads.indices.filter {
            ![DiagnosticTaskReadReason.normalRead, .ignoredUnscopedUsage].contains(reads[$0].metrics.reason)
        }.suffix(64))
        for index in reads.indices.reversed() where selectedReads.count < 128 { selectedReads.insert(index) }
        return Self(eventCount: records.filter { if case .taskTrace = $0.event { return true }; return false }.count,
            evidenceComplete: !snapshots.isEmpty && snapshots.allSatisfy(\.evidenceComplete) && !deliveryGap, globalRecordingGap: gap,
            deliveryEvidenceIncomplete: deliveryGap, observationGaps: Array(observationGaps.suffix(64)),
            omittedObservationGaps: max(0, observationGaps.count - 64),
            summaryOmittedSnapshots: max(0, snapshots.count - 64), summaryOmittedChanges: max(0, changes.count - 256),
            summaryOmittedReads: reads.count - selectedReads.count,
            summaryOmittedLifecycles: max(0, lifecycles.count - 256), snapshots: Array(snapshots.suffix(64)),
            memberChanges: Array(changes.suffix(256)), reads: selectedReads.sorted().map { reads[$0] },
            lifecycles: Array(lifecycles.suffix(256)))
    }

    var summary: String {
        guard eventCount > 0 else {
            return "任务追踪：选定范围内无可用逐任务证据，不能据此断言没有运行任务。"
        }
        var lines = ["任务追踪：\(evidenceComplete ? "所列检查点完整" : "证据不完整")；实体显示可见性未知；跨进程任务关联未知。",
            "展示快照 \(snapshots.count)；成员变化 \(memberChanges.count)；读取观察 \(reads.count)。",
            "摘要省略快照/成员/读取：\(summaryOmittedSnapshots)/\(summaryOmittedChanges)/\(summaryOmittedReads)；完整采集内容见 events.jsonl。"]
        lines.append("生命周期观察列出 \(min(lifecycles.count, 24))；摘要省略 \(summaryOmittedLifecycles + max(0, lifecycles.count - 24))。本版本采集会合并连续同类读取失败：首条及每 30 秒记录一次，失败分类变化或恢复后再次失败另行记录。")
        lines.append("无轮次用量事件按任务和文件代次采样：首条及每 30 秒记录一次；这类事件不改变任务状态。")
        for gap in observationGaps.suffix(8) { lines.append("任务观察缺口：\(gap.reason.rawValue)，丢弃 \(gap.droppedCount) 条，批次 \(gap.context.batch)。") }
        for snapshot in snapshots.suffix(12) {
            let ref = snapshot.reference
            lines.append("快照 \(ref.snapshotID.uuidString)：运行 \(ref.runningCount)，未知 \(ref.unknownCount)，证据链 \(snapshot.evidenceComplete ? "完整" : "不完整")；快照结构 \(snapshot.integrity.reason.rawValue)；前序缺失 \(snapshot.predecessorMissing)，身份缺失 \(snapshot.identityMissing)。")
            if let removed = snapshot.removedCountedMembers, !removed.isEmpty { lines.append("  退出计数：" + removed.map(\.uuidString).joined(separator: ", ")) }
            if let added = snapshot.addedCountedMembers, !added.isEmpty { lines.append("  加入计数：" + added.map(\.uuidString).joined(separator: ", ")) }
            let delivery = snapshot.consumption.map { "\($0.consumer?.rawValue ?? $0.surface.rawValue):\($0.action.rawValue)/\($0.reason.rawValue)" }
            lines.append("  消费观察：" + (delivery.isEmpty ? "无记录" : delivery.joined(separator: ", ")))
            if snapshot.omittedConsumption > 0 { lines.append("  摘要省略消费观察：\(snapshot.omittedConsumption)；见 events.jsonl。") }
        }
        for change in memberChanges.suffix(24) {
            lines.append("批次 \(change.context.batch)：任务 \(change.identity.taskAlias.uuidString)，counted \(change.countedBefore) → \(change.countedAfter)，原因 \(change.reason.rawValue)。")
        }
        for lifecycle in lifecycles.suffix(24) {
            let t = lifecycle.transition
            lines.append("批次 \(lifecycle.context.batch)：任务 \(lifecycle.identity.taskAlias.uuidString)，状态 \(t.before.rawValue) → \(t.after.rawValue)，原因 \(t.reason.rawValue)，证据 \(t.evidence.rawValue)，接受 \(t.accepted)。")
        }
        let failures = reads.filter { ![DiagnosticTaskReadReason.normalRead, .ignoredUnscopedUsage].contains($0.metrics.reason) }
        let ignored = reads.filter { $0.metrics.reason == .ignoredUnscopedUsage }
        for read in Array(failures.suffix(12)) + Array(ignored.suffix(4)) {
            func number(_ value: UInt64?) -> String { value.map(String.init) ?? "未知" }
            let m = read.metrics
            lines.append("批次 \(read.context.batch)：任务 \(read.identity.taskAlias.uuidString)：\(m.reason.rawValue)，文件 \(number(m.fileBytes)) B，位置 \(number(m.offsetBefore)) → \(number(m.offsetAfter))，读取 \(number(m.readBytes)) B，跳过 \(number(m.skippedBytes)) B。")
            if m.recordStartOffset != nil {
                lines.append("  记录位置 \(number(m.recordStartOffset)) → \(number(m.recordEndOffset))，文件代次 \(number(m.journalGeneration))，事件 \(m.lifecycleType?.rawValue ?? "未知")，解析错误 \(m.decodeIssue?.rawValue ?? "无")。")
            }
            if let failure = m.failureCategory { lines.append("  读取失败分类：\(failure.rawValue)。") }
        }
        return lines.joined(separator: "\n")
    }
}
