import Foundation

/// 形如 `v1.2.3` / `1.2.3` / `v2` 的版本号标签。建标签弹窗靠它把
/// 「上一个版本号」推进成下一个候选：v0.1.1 → v0.1.2，
/// 发版时手敲版本号这种体力活就省了。
struct VersionTag: Comparable {
    /// `v0.1.1` → `[0, 1, 1]`。段数不限死 3，`v2`、`1.0.0.1` 也算版本号。
    let numbers: [Int]
    /// 原名带不带 `v` 前缀。下一个候选沿用仓库自己的风格 ——
    /// 一直用 `0.1.1` 的仓库不该突然被塞个 `v0.1.2`。
    let hasPrefixV: Bool

    init(numbers: [Int], hasPrefixV: Bool) {
        self.numbers = numbers
        self.hasPrefixV = hasPrefixV
    }

    /// 从标签名解析。只收纯数字段 —— `v1.0.0-beta`、`release-1`、`wip`
    /// 这类不是版本号推进的对象，返回 nil。
    init?(_ rawValue: String) {
        var digits = rawValue
        let hasPrefixV = rawValue.hasPrefix("v")
        if hasPrefixV { digits.removeFirst() }
        let parts = digits.split(separator: ".", omittingEmptySubsequences: false)
        // Int() 也收带符号的段（"+1"、"-1"），先验纯数字再转换 ——
        // 否则 v2.-1 这种怪标签会抢走最高版本的位置，把候选带偏。
        let numbers = parts.compactMap { part -> Int? in
            guard part.allSatisfy(\.isNumber) else { return nil }
            return Int(part)
        }
        guard !numbers.isEmpty, numbers.count == parts.count else { return nil }
        self.numbers = numbers
        self.hasPrefixV = hasPrefixV
    }

    var rawValue: String {
        (hasPrefixV ? "v" : "") + numbers.map(String.init).joined(separator: ".")
    }

    /// 下一个候选：末段 +1，不进位 —— v0.1.9 之后是 v0.1.10。
    func next() -> VersionTag {
        var bumped = numbers
        bumped[bumped.count - 1] += 1
        return VersionTag(numbers: bumped, hasPrefixV: hasPrefixV)
    }

    /// 逐段按数值比大小，段数少的用 0 补齐（v0.1 < v0.1.0）；
    /// 补齐后仍相等时段多的算大，保证 max() 稳定二选一。
    static func < (lhs: VersionTag, rhs: VersionTag) -> Bool {
        let count = max(lhs.numbers.count, rhs.numbers.count)
        for index in 0..<count {
            let left = index < lhs.numbers.count ? lhs.numbers[index] : 0
            let right = index < rhs.numbers.count ? rhs.numbers[index] : 0
            if left != right { return left < right }
        }
        return lhs.numbers.count < rhs.numbers.count
    }

    /// 一堆标签名里最高版本号的下一个候选。仓库里还没有任何
    /// 版本号样子的标签时返回 nil，弹窗保持空输入。
    static func suggestedNext(after names: [String]) -> String? {
        names.compactMap(VersionTag.init).max()?.next().rawValue
    }
}
