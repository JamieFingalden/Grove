import Foundation

/// 大 diff 的分组审查计划。借鉴 alibaba/open-code-review 的分组独立审查
/// （divide & conquer）：超出预算时不再截断内容换 uncertain 结论，而是把
/// 相关文件捆成小组分别送审，再确定性合并结果。相关性用目录近似 ——
/// 同目录的改动大概率共享上下文（接口与调用方、成套的资源文件），
/// 这也接近该工具在无 LLM 分组时的逐文件回退策略，但不额外花一次模型调用。
enum DiffGroupPlanner {
    /// 组数上限，控制单次审查的成本与时延。排不下的文件进未覆盖清单，
    /// 合并结果时把 ready 降级为 uncertain。
    static let maxGroups = 8

    struct Plan: Sendable, Equatable {
        /// 每组独立送审的文件；组内保持 diff 原始顺序。
        var groups: [[FileDiff]]
        /// 组数达上限后没能送审的文件名（按原始 diff 顺序）。
        var uncoveredFiles: [String]
        /// 内容被确定性排除的敏感文件名。
        var secretFiles: [String]
        /// false = 一组就能装下（保持单次调用的原路径）。
        var isSplit: Bool
    }

    static func plan(files: [FileDiff], byteLimit: Int, maxGroups: Int = DiffGroupPlanner.maxGroups) -> Plan {
        let secretFiles = files.filter { DiffBudget.isSecretFile($0) }
        let secretNames = secretFiles.map(\.displayPath)
        let reviewable = files.filter { !DiffBudget.isSecretFile($0) }
        let total = Data(PullRequestReviewPromptBuilder.unifiedDiff(reviewable).utf8).count
        guard reviewable.count > 1, total > max(0, byteLimit) else {
            return Plan(groups: [reviewable], uncoveredFiles: [], secretFiles: secretNames, isSplit: false)
        }

        // 按目录分桶，桶内保持原始顺序。目录是相关性的最稳代理：
        // 同目录的接口与调用方、成套的本地化文件会进同一次上下文。
        var buckets: [Bucket] = []
        var bucketIndexByKey: [String: Int] = [:]
        for file in reviewable {
            let key = file.directory ?? ""
            if let index = bucketIndexByKey[key] {
                buckets[index].files.append(file)
            } else {
                bucketIndexByKey[key] = buckets.count
                buckets.append(Bucket(key: key, files: [file], isLowValue: false, bytes: 0))
            }
        }
        for index in buckets.indices {
            buckets[index].isLowValue = buckets[index].files.allSatisfy { DiffBudget.isLowValue($0.displayPath) }
            buckets[index].bytes = Data(
                PullRequestReviewPromptBuilder.unifiedDiff(buckets[index].files).utf8
            ).count
        }

        // 核心桶优先（按体量降序），低价值桶垫后：组数不够时先裁测试、锁文件。
        let ordered = buckets.enumerated().sorted { lhs, rhs in
            if lhs.element.isLowValue != rhs.element.isLowValue { return !lhs.element.isLowValue }
            if lhs.element.bytes != rhs.element.bytes { return lhs.element.bytes > rhs.element.bytes }
            return lhs.offset < rhs.offset
        }.map(\.element)

        // 首次适配装箱：每组建满一个 byteLimit 的上下文，装不下的桶开新组；
        // 单桶超限也独立成组，组内截断由 DiffBudget 在构建提示词时处理。
        var groups: [Group] = []
        for bucket in ordered {
            var placed = false
            for index in groups.indices where groups[index].bytes + bucket.bytes <= byteLimit {
                groups[index].files.append(contentsOf: bucket.files)
                groups[index].bytes += bucket.bytes
                placed = true
                break
            }
            if !placed {
                groups.append(Group(files: bucket.files, bytes: bucket.bytes))
            }
        }

        // 组数不够时先保住核心代码组（混入核心文件的组也算核心），纯测试/
        // 锁文件组让位 —— 只按体量排序会让大体积测试组挤掉小生产组，
        // 和装箱时的核心优先策略自相矛盾。体量只做同层内的排序。
        let ranked = groups.enumerated().sorted { lhs, rhs in
            let lhsCore = !lhs.element.files.allSatisfy { DiffBudget.isLowValue($0.displayPath) }
            let rhsCore = !rhs.element.files.allSatisfy { DiffBudget.isLowValue($0.displayPath) }
            if lhsCore != rhsCore { return lhsCore }
            if lhs.element.bytes != rhs.element.bytes { return lhs.element.bytes > rhs.element.bytes }
            return lhs.offset < rhs.offset
        }.map(\.element)
        let kept = ranked.prefix(maxGroups)
        let dropped = ranked.dropFirst(maxGroups).flatMap(\.files)

        // 未覆盖名单按原始 diff 顺序列出；组内文件也还原成 diff 顺序送审。
        let originalOrder = originalPathOrder(reviewable)
        return Plan(
            groups: kept.map { group in
                group.files.sorted { originalOrder[$0.displayPath] ?? 0 < originalOrder[$1.displayPath] ?? 0 }
            },
            uncoveredFiles: dropped.map(\.displayPath)
                .sorted { originalOrder[$0] ?? 0 < originalOrder[$1] ?? 0 },
            secretFiles: secretNames,
            isSplit: true
        )
    }

    private struct Bucket {
        var key: String
        var files: [FileDiff]
        var isLowValue: Bool
        var bytes: Int
    }

    private struct Group {
        var files: [FileDiff]
        var bytes: Int
    }

    private static func originalPathOrder(_ files: [FileDiff]) -> [String: Int] {
        var order: [String: Int] = [:]
        for (index, file) in files.enumerated() where order[file.displayPath] == nil {
            order[file.displayPath] = index
        }
        return order
    }
}
