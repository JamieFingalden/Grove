import Foundation

/// 词级（行内）差异：对 hunk 里成对的删除行/新增行，找出**真正变化的片段**。
///
/// review 一个几千行的 diff 时，最费眼的就是「这行到底改了哪几个字」——
/// 整行红绿底只告诉你这行变了，不告诉你变了什么。
///
/// 算法取巧但够用（和 GitHub 的 wdiff 同级）：
/// 对齐一对删/增行后求公共前缀和公共后缀，中间那段就是变化区。
/// 前缀天然落在两行第一个不同的字符上，所以切分点自动是合理的词边界。
/// 没配上对的行（纯删或纯增）整行都是变化。
enum DiffWordHighlight {
    /// 返回按行 id 索引的变化区间列表。上下文行和元信息行不会出现。
    static func ranges(for lines: [DiffLine]) -> [Int: [Range<String.Index>]] {
        var result: [Int: [Range<String.Index>]] = [:]

        var deletions: [DiffLine] = []
        var additions: [DiffLine] = []

        func flush() {
            guard !deletions.isEmpty || !additions.isEmpty else { return }
            let paired = min(deletions.count, additions.count)
            // 按位置配对：第 i 个删除行对第 i 个新增行。git 的 diff 通常
            // 语义对齐得不错（尤其开了 --indent-heuristic 之后），错位时
            // 高亮会偏大，但不会错到误导。
            for index in 0..<paired {
                let (delRange, addRange) = changedSpans(deletions[index].text, additions[index].text)
                if let delRange { result[deletions[index].id, default: []].append(delRange) }
                if let addRange { result[additions[index].id, default: []].append(addRange) }
            }
            // 配对剩下的整行都是变化。
            for line in deletions.dropFirst(paired) { result[line.id, default: []].append(line.text.startIndex..<line.text.endIndex) }
            for line in additions.dropFirst(paired) { result[line.id, default: []].append(line.text.startIndex..<line.text.endIndex) }
            deletions.removeAll()
            additions.removeAll()
        }

        for line in lines {
            switch line.kind {
            case .deletion: deletions.append(line)
            case .addition: additions.append(line)
            case .context, .noNewline: flush()
            }
        }
        flush()
        return result
    }

    /// 汇总一个文件全部 hunk 的行内差异。
    static func ranges(for file: FileDiff) -> [Int: [Range<String.Index>]] {
        var result: [Int: [Range<String.Index>]] = [:]
        for hunk in file.hunks {
            result.merge(ranges(for: hunk.lines)) { current, _ in current }
        }
        return result
    }

    /// 一对旧/新文本的变化区间（去掉公共前缀和公共后缀）。
    /// 两侧只有空白差异（或完全相同）时返回 nil —— 没有值得强调的内容。
    private static func changedSpans(_ old: String, _ new: String) -> (Range<String.Index>?, Range<String.Index>?) {
        if old == new { return (nil, nil) }

        var prefix = 0
        var oldChars = Array(old)
        var newChars = Array(new)
        while prefix < oldChars.count, prefix < newChars.count,
              oldChars[prefix] == newChars[prefix] {
            prefix += 1
        }

        var suffix = 0
        while suffix < oldChars.count - prefix, suffix < newChars.count - prefix,
              oldChars[oldChars.count - 1 - suffix] == newChars[newChars.count - 1 - suffix] {
            suffix += 1
        }

        func span(_ text: String, _ chars: [Character]) -> Range<String.Index>? {
            let lower = text.index(text.startIndex, offsetBy: prefix)
            let upper = text.index(text.startIndex, offsetBy: chars.count - suffix)
            guard lower < upper else { return nil }
            return lower..<upper
        }

        // 只比空白（缩进调整、行尾空格）的差异不值得强调。
        let oldSpan = span(old, oldChars)
        let newSpan = span(new, newChars)
        if trimmed(oldSpan, in: old) && trimmed(newSpan, in: new) { return (nil, nil) }

        return (oldSpan, newSpan)
    }

    /// 区间内容全是空白 → true。
    private static func trimmed(_ range: Range<String.Index>?, in text: String) -> Bool {
        guard let range else { return true }
        return text[range].trimmingCharacters(in: .whitespaces).isEmpty
    }
}
