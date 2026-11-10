import Foundation

/// 提交图的 lane 分配器。它只根据真实 parent 边计算布局，绝不改写 Git DAG。
enum CommitGraphLayout {
    /// 固定 lane 的上下文。分支在 Git 中只是指向 tip 的 ref；这里先从 tip 沿 parent
    /// 回溯，再把 main/current 各自的真实祖先路径固定到对应位置。
    struct Context: Sendable {
        var defaultBranch: String?
        var currentBranch: String?

        static let empty = Context(defaultBranch: nil, currentBranch: nil)
    }

    /// 一条线段：从行内某个 lane 连到另一个 lane。
    struct Link: Hashable, Sendable {
        var from: Int
        var to: Int
        /// 0 = main，1 = 当前分支，2 = 普通动态路径。
        var color: Int
        /// 这段线所属的真实 Git 边。穿过无关行时也不丢失，因此 focus 能精确高亮。
        var sourceOID: String?
        var targetOID: String?
        var isFocused = false
    }

    struct Row: Hashable, Sendable, Identifiable {
        var oid: String
        var commitLane: Int
        var color: Int
        var incoming: [Link]
        var outgoing: [Link]
        var isMerge: Bool
        var isFocused = false
        var isDimmed = false

        var id: String { oid }
    }

    struct Graph: Sendable {
        var rows: [Row]
        /// 取整段历史里的最大活跃 lane 数，保证列表滚动时图列不左右跳动。
        var laneCount: Int
        private var fixedLaneCount: Int
        private var parentsByOID: [String: [String]]

        init(
            rows: [Row],
            laneCount: Int,
            fixedLaneCount: Int,
            parentsByOID: [String: [String]]
        ) {
            self.rows = rows
            self.laneCount = laneCount
            self.fixedLaneCount = fixedLaneCount
            self.parentsByOID = parentsByOID
        }

        static let empty = Graph(rows: [], laneCount: 0, fixedLaneCount: 0, parentsByOID: [:])

        /// 标记聚焦路径，突出显示选中的提交血缘并弱化其余分支。
        func projected(maxDynamicLanes: Int = 0, focusOID: String?) -> Graph {
            guard let focusOID, parentsByOID[focusOID] != nil else {
                return self
            }
            let focusedOIDs = focusPathOIDs(from: focusOID)
            return Graph(
                rows: rows.map { row in
                    var copy = row
                    let isRowFocused = focusedOIDs.contains(row.oid)
                    copy.isFocused = isRowFocused
                    copy.isDimmed = !isRowFocused
                    copy.incoming = row.incoming.map { link in
                        var copy = link
                        copy.isFocused = focusedOIDs.contains(link.sourceOID ?? "")
                            && focusedOIDs.contains(link.targetOID ?? "")
                        return copy
                    }
                    copy.outgoing = row.outgoing.map { link in
                        var copy = link
                        copy.isFocused = focusedOIDs.contains(link.sourceOID ?? "")
                            && focusedOIDs.contains(link.targetOID ?? "")
                        return copy
                    }
                    return copy
                },
                laneCount: laneCount,
                fixedLaneCount: fixedLaneCount,
                parentsByOID: parentsByOID
            )
        }

        private func focusPathOIDs(from focusOID: String) -> Set<String> {
            var childrenByOID: [String: [String]] = [:]
            for (oid, parents) in parentsByOID {
                for parent in parents { childrenByOID[parent, default: []].append(oid) }
            }
            var result = traverse(from: focusOID, through: parentsByOID)
            var pending = [focusOID]
            while let oid = pending.popLast() {
                for child in childrenByOID[oid] ?? [] {
                    guard let parents = parentsByOID[child] else { continue }
                    result.insert(child)
                    // feature 的普通提交沿第一 parent 向下延续；当它作为 merge 的第二
                    // parent 汇入主线时，路径在 merge 点结束，避免误选中之后的无关主线。
                    if parents.first == oid { pending.append(child) }
                }
            }
            return result
        }

        private func traverse(from start: String, through edges: [String: [String]]) -> Set<String> {
            var visited: Set<String> = []
            var pending = [start]
            while let oid = pending.popLast(), visited.insert(oid).inserted {
                pending.append(contentsOf: edges[oid] ?? [])
            }
            return visited
        }
    }

    private struct Lane: Sendable {
        var waitingFor: String
        var sourceOID: String
        var color: Int
    }

    private enum Color {
        static let main = 0
        static let current = 1
        static let dynamicStart = 2
    }

    /// 传入的提交必须是 `--topo-order` 的顺序。
    static func build(_ commits: [CommitSummary], context: Context = .empty) -> Graph {
        guard !commits.isEmpty else { return .empty }

        let parentsByOID = Dictionary(uniqueKeysWithValues: commits.map { ($0.oid, $0.parents) })
        let mainTip = tipOID(named: context.defaultBranch, in: commits)
        let currentTip = tipOID(named: context.currentBranch, in: commits)
        // main 的视觉主线遵循 Git 约定的第一 parent；若把 merge 的第二 parent
        // 也算进来，被合入的 feature 会错误地挤到 main lane。
        let mainLineage = firstParentAncestors(of: mainTip, parentsByOID: parentsByOID)
        let currentLineage = firstParentAncestors(of: currentTip, parentsByOID: parentsByOID)

        // 共同祖先属于 main lane。当前分支只在从分叉到汇合的独有区间占 lane 1。
        let currentOnly = currentLineage.subtracting(mainLineage)
        let hasMainLane = !mainLineage.isEmpty
        let hasCurrentLane = !currentOnly.isEmpty
        let dynamicStart = (hasMainLane ? 1 : 0) + (hasCurrentLane ? 1 : 0)

        func preferredLane(for oid: String) -> Int? {
            if mainLineage.contains(oid) { return 0 }
            if currentOnly.contains(oid) { return hasMainLane ? 1 : 0 }
            return nil
        }

        func preferredColor(for oid: String) -> Int? {
            if mainLineage.contains(oid) { return Color.main }
            if currentOnly.contains(oid) { return Color.current }
            return nil
        }

        // 预留固定 lane，普通路径永远不能占用它们。这样 main/current 在任意拓扑序中
        // 都不会被更早遇到的 feature 路径挤走。
        var lanes = Array<Lane?>(repeating: nil, count: dynamicStart)
        var rows: [Row] = []
        var laneCount = dynamicStart
        var nextDynamicColor = Color.dynamicStart

        func allocateDynamicColor() -> Int {
            let color = nextDynamicColor
            nextDynamicColor += 1
            return color
        }

        func firstFreeDynamicLane() -> Int {
            if let index = lanes.indices.first(where: { $0 >= dynamicStart && lanes[$0] == nil }) {
                return index
            }
            lanes.append(nil)
            return lanes.count - 1
        }

        func assign(_ oid: String, sourceOID: String, to lane: Int, color: Int) {
            if lane >= lanes.count {
                lanes.append(contentsOf: repeatElement(nil, count: lane - lanes.count + 1))
            }
            lanes[lane] = Lane(waitingFor: oid, sourceOID: sourceOID, color: color)
        }

        func allocate(for oid: String, sourceOID: String) -> Int {
            if let preferred = preferredLane(for: oid), lanes[preferred] == nil {
                let color = preferredColor(for: oid) ?? allocateDynamicColor()
                assign(oid, sourceOID: sourceOID, to: preferred, color: color)
                return preferred
            }
            let lane = firstFreeDynamicLane()
            let color = allocateDynamicColor()
            assign(oid, sourceOID: sourceOID, to: lane, color: color)
            return lane
        }

        func allocateDynamicLane(for oid: String, sourceOID: String) -> Int {
            let lane = firstFreeDynamicLane()
            let color = allocateDynamicColor()
            assign(oid, sourceOID: sourceOID, to: lane, color: color)
            return lane
        }

        for commit in commits {
            let before = lanes
            let waiting = before.indices.filter { before[$0]?.waitingFor == commit.oid }
            let preferred = preferredLane(for: commit.oid)
            let commitLane: Int
            if let preferred, before[preferred]?.waitingFor == commit.oid || before[preferred] == nil {
                commitLane = preferred
                if lanes[commitLane] == nil {
                    assign(
                        commit.oid,
                        sourceOID: commit.oid,
                        to: commitLane,
                        color: preferredColor(for: commit.oid) ?? Color.main
                    )
                }
            } else if let waitingLane = waiting.first {
                commitLane = waitingLane
            } else {
                commitLane = allocate(for: commit.oid, sourceOID: commit.oid)
            }

            let commitColor = (commitLane < dynamicStart ? preferredColor(for: commit.oid) : nil)
                ?? lanes[commitLane]?.color
                ?? allocateDynamicColor()
            var incoming: [Link] = []
            for lane in before.indices {
                guard let state = before[lane] else { continue }
                incoming.append(Link(
                    from: lane,
                    to: state.waitingFor == commit.oid ? commitLane : lane,
                    color: state.color,
                    sourceOID: state.sourceOID,
                    targetOID: state.waitingFor
                ))
            }

            // 汇入当前提交的其余 lane 生命周期在这里结束。
            for lane in waiting where lane != commitLane {
                lanes[lane] = nil
            }

            if let firstParent = commit.parents.first {
                // 第一 parent 延续当前路径；只有在进入固定主/当前分支时才变色。
                let continuationColor: Int
                if let pref = preferredColor(for: firstParent), preferredLane(for: firstParent) == commitLane {
                    continuationColor = pref
                } else {
                    continuationColor = commitColor
                }
                assign(firstParent, sourceOID: commit.oid, to: commitLane, color: continuationColor)
            } else {
                lanes[commitLane] = nil
            }

            var extraParentLanes: [Int] = []
            for parent in commit.parents.dropFirst() {
                if let existing = lanes.indices.first(where: { lanes[$0]?.waitingFor == parent }) {
                    extraParentLanes.append(existing)
                    continue
                }
                extraParentLanes.append(allocateDynamicLane(for: parent, sourceOID: commit.oid))
            }

            var outgoing: [Link] = []
            for lane in lanes.indices {
                guard let state = lanes[lane] else { continue }
                if lane == commitLane, !commit.parents.isEmpty {
                    outgoing.append(Link(
                        from: commitLane, to: lane, color: state.color,
                        sourceOID: state.sourceOID, targetOID: state.waitingFor
                    ))
                } else if extraParentLanes.contains(lane) {
                    // 如果这个车道在当前行之前就是直穿车道（在等待更早的祖先），
                    // 它原本直行的连线必须继续向下延伸，否则直穿线在 midY 会被生生截断！
                    if before.indices.contains(lane), let beforeState = before[lane], beforeState.waitingFor != commit.oid {
                        outgoing.append(Link(
                            from: lane, to: lane, color: beforeState.color,
                            sourceOID: beforeState.sourceOID, targetOID: beforeState.waitingFor
                        ))
                    }
                    outgoing.append(Link(
                        from: commitLane, to: lane, color: state.color,
                        sourceOID: state.sourceOID, targetOID: state.waitingFor
                    ))
                } else {
                    outgoing.append(Link(
                        from: lane, to: lane, color: state.color,
                        sourceOID: state.sourceOID, targetOID: state.waitingFor
                    ))
                }
            }

            rows.append(Row(
                oid: commit.oid,
                commitLane: commitLane,
                color: commitColor,
                incoming: incoming,
                outgoing: outgoing,
                isMerge: commit.isMerge
            ))
            laneCount = max(laneCount, lanes.count)

            // 只回收动态区的尾部空位；固定 lane 永远留在原位置。
            while lanes.count > dynamicStart, lanes.last == nil {
                lanes.removeLast()
            }
        }

        return Graph(
            rows: rows,
            laneCount: laneCount,
            fixedLaneCount: dynamicStart,
            parentsByOID: parentsByOID
        )
    }

    private static func tipOID(named branch: String?, in commits: [CommitSummary]) -> String? {
        let candidates = [branch].compactMap { $0 }.filter { !$0.isEmpty } + ["main", "master", "develop"]
        var seen = Set<String>()
        for name in candidates where seen.insert(name).inserted {
            // 1. 直接通过 ref 匹配分支 tip
            if let direct = commits.first(where: { commit in
                commit.refs.contains { ref in
                    ref.name == name || ref.name.hasSuffix("/\(name)")
                }
            })?.oid {
                return direct
            }
            // 2. 如果 tip 不在当前拉取的窗口内，从包含 "into 'name'" 的合并提交回溯主干
            if let merge = commits.first(where: { commit in
                commit.subject.contains("into '\(name)'") || commit.subject.contains("into \(name)")
            })?.oid {
                return merge
            }
        }
        return nil
    }

    private static func ancestors(
        of tip: String?,
        parentsByOID: [String: [String]]
    ) -> Set<String> {
        guard let tip else { return [] }
        var result: Set<String> = []
        var pending = [tip]
        while let oid = pending.popLast(), result.insert(oid).inserted {
            pending.append(contentsOf: parentsByOID[oid] ?? [])
        }
        return result
    }

    private static func firstParentAncestors(
        of tip: String?,
        parentsByOID: [String: [String]]
    ) -> Set<String> {
        guard let tip else { return [] }
        var result: Set<String> = []
        var current: String? = tip
        while let oid = current, result.insert(oid).inserted {
            current = parentsByOID[oid]?.first
        }
        return result
    }
}
