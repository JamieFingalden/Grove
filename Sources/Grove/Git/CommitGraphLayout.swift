import Foundation

/// 把一串提交排成「道」（lane），算出每一行该画哪些线段。
///
/// 这是提交图的核心，做成纯函数是因为它是唯一值得单测的部分：
/// 分叉、合并、多条道并行、道被释放后复用 —— 这些组合靠肉眼看渲染结果验证不了。
///
/// **算法。** 从最新的提交往下扫，维护一组「道」，每条道记着它**下一个在等谁**：
///
/// - 当前提交出现在哪条道上，它就占那条道；没有道在等它就新开一条
///   （这是分支的起点，从上往下看是一条新出现的线）。
/// - 它的**第一个父提交**继续占用同一条道 —— 这样主线在图上是一条直线。
/// - 合并提交的其余父提交各自找一条道：已经有道在等它就复用（两条线在此汇合），
///   否则新开一条（画成从这里岔出去）。
/// - 多条道同时在等当前提交时，它们全部收敛到提交所在的道，其余的道被释放。
///
/// **一行分上下两半画。** 上半是「进来的线」从行顶收敛到提交点，下半是「出去的线」
/// 从提交点发散到行底。穿行而过的道在上下两半各有一段，接起来就是一条直线。
/// 不这么拆的话，合并提交那一行的线会画成穿过圆点的直线，看不出是在这里汇合的。
enum CommitGraphLayout {
    /// 一条线段：从行内某个位置连到另一个位置。
    struct Link: Hashable, Sendable {
        var from: Int
        var to: Int
        /// 颜色索引。同一条道在存活期间颜色不变，视觉上才跟得住。
        var color: Int
    }

    struct Row: Hashable, Sendable, Identifiable {
        var oid: String
        /// 提交圆点画在第几条道上。
        var commitLane: Int
        var color: Int
        /// 上半行：从行顶画到提交点所在高度。
        var incoming: [Link]
        /// 下半行：从提交点所在高度画到行底。
        var outgoing: [Link]
        var isMerge: Bool

        var id: String { oid }
    }

    struct Graph: Sendable {
        var rows: [Row]
        /// 所有行里用到的最大道数。图形列的宽度按它算 ——
        /// 每行各算各的宽度会让整列左右抖动。
        var laneCount: Int

        static let empty = Graph(rows: [], laneCount: 0)
    }

    /// 传入的提交必须是 `--topo-order` 的顺序。
    ///
    /// 默认的时间序会把不同分支的提交按时间穿插在一起，画出来的道会反复跳来跳去；
    /// 拓扑序把同一条分支的提交聚在一起，图才读得懂。git 自己的 `--graph` 也是
    /// 默认开启拓扑序的。
    static func build(_ commits: [CommitSummary]) -> Graph {
        // 每条道正在等待的提交 oid。nil 表示这条道空着，可以被复用。
        var lanes: [String?] = []
        // 每条道的颜色。道被释放再复用时会重新取色，避免两条不相干的线同色相接。
        var laneColors: [Int] = []
        var nextColor = 0
        var rows: [Row] = []
        var laneCount = 0

        /// 找一条空道，没有就新开一条。
        func allocateLane(for oid: String) -> Int {
            if let free = lanes.firstIndex(where: { $0 == nil }) {
                lanes[free] = oid
                laneColors[free] = nextColor
                nextColor += 1
                return free
            }
            lanes.append(oid)
            laneColors.append(nextColor)
            nextColor += 1
            return lanes.count - 1
        }

        for commit in commits {
            let before = lanes
            let beforeColors = laneColors

            // 这个提交占哪条道：优先用已经在等它的那条（编号最小的，
            // 让主线尽量待在左边），没有就新开 —— 那是一条分支的起点。
            let waiting = before.indices.filter { before[$0] == commit.oid }
            let commitLane = waiting.first ?? allocateLane(for: commit.oid)
            let commitColor = laneColors[commitLane]

            // 上半行：等这个提交的道全部收敛到 commitLane，其余的直穿。
            var incoming: [Link] = []
            for lane in before.indices where before[lane] != nil {
                if before[lane] == commit.oid {
                    incoming.append(Link(from: lane, to: commitLane, color: beforeColors[lane]))
                } else {
                    incoming.append(Link(from: lane, to: lane, color: beforeColors[lane]))
                }
            }

            // 收敛进来的道除了 commitLane 之外都用完了，释放掉。
            for lane in waiting where lane != commitLane {
                lanes[lane] = nil
            }

            // 第一个父提交继承本道 —— 主线因此是一条直线。
            if let first = commit.parents.first {
                lanes[commitLane] = first
            } else {
                // 根提交，这条道到此为止。
                lanes[commitLane] = nil
            }

            // 其余父提交（只有合并提交才有）：已有道在等就复用，否则新开。
            var extraParentLanes: [Int] = []
            for parent in commit.parents.dropFirst() {
                if let existing = lanes.firstIndex(where: { $0 == parent }) {
                    extraParentLanes.append(existing)
                } else {
                    extraParentLanes.append(allocateLane(for: parent))
                }
            }

            // 下半行：从提交点发散出去的线 + 其余直穿的道。
            var outgoing: [Link] = []
            for lane in lanes.indices where lanes[lane] != nil {
                let isFromThisCommit = lane == commitLane && commit.parents.isEmpty == false
                if isFromThisCommit {
                    outgoing.append(Link(from: commitLane, to: lane, color: commitColor))
                } else if extraParentLanes.contains(lane) {
                    outgoing.append(Link(from: commitLane, to: lane, color: laneColors[lane]))
                } else {
                    outgoing.append(Link(from: lane, to: lane, color: laneColors[lane]))
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

            laneCount = max(laneCount, before.count, lanes.count)

            // 把末尾的空道回收掉，免得道数只涨不跌、图形列越来越宽。
            while let last = lanes.last, last == nil {
                lanes.removeLast()
                laneColors.removeLast()
            }
        }

        return Graph(rows: rows, laneCount: laneCount)
    }
}
