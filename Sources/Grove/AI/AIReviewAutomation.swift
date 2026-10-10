import Foundation
import CryptoKit

enum AIReviewAutomation {
    static func marker(head: String, area: String) -> String {
        "<!-- grove-ai-review:\(head):\(area) -->"
    }

    static func contains(_ marker: String, in threads: [ReviewThread]) -> Bool {
        threads.contains { thread in thread.notes.contains { $0.body.contains(marker) } }
    }

    static func issueKey(_ finding: PullRequestAIReview.Assessment) -> String {
        let identity = [finding.area.rawValue, finding.file ?? "", finding.line.map(String.init) ?? "",
                        finding.summary.trimmingCharacters(in: .whitespacesAndNewlines)].joined(separator: "\n")
        return SHA256.hash(data: Data(identity.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    static func visibleBody(_ body: String) -> String {
        body.components(separatedBy: "\n").filter {
            let line = $0.trimmingCharacters(in: .whitespaces).drop(while: { $0 == ">" || $0.isWhitespace })
            return !(line.hasPrefix("<!-- grove-ai-review:") && line.hasSuffix("-->"))
        }.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func discussionContext(_ threads: [ReviewThread]) -> String {
        let discussions = threads.filter { !$0.isSystemOnly }.sorted {
            if $0.isResolved != $1.isResolved { return !$0.isResolved }
            return ($0.firstNote?.createdAt ?? .distantPast) > ($1.firstNote?.createdAt ?? .distantPast)
        }
        guard !discussions.isEmpty else { return "（没有历史讨论。）" }
        let text = discussions.map { thread in
            let location = thread.filePath.map { "\($0):\(thread.line ?? 0)" } ?? "整体讨论"
            let notes = thread.notes.filter { !$0.isSystem }.map {
                "\($0.authorLogin)：\($0.body)"
            }.joined(separator: "\n")
            return "讨论 \(thread.id) · \(location) · \(thread.isResolved ? "已解决" : "未解决") · \(thread.isOutdated ? "旧版本定位" : "当前定位")\n代码片段：\n\(thread.diffHunk ?? "（无）")\n发言与回复：\n\(notes)"
        }.joined(separator: "\n\n")
        let limit = 64 * 1024
        let bounded = CommitPromptBuilder.limited(text, byteLimit: limit)
        return bounded + (text.utf8.count > limit ? "\n（历史讨论超出预算，已优先保留未解决讨论；省略部分不能视为已解决。）" : "")
    }

    static func location(for assessment: PullRequestAIReview.Assessment, files: [FileDiff]) -> ReviewLocation? {
        guard let path = assessment.file, let number = assessment.line,
              let file = files.first(where: { $0.newPath == path || $0.oldPath == path || $0.displayPath == path }),
              let line = file.hunks.flatMap(\.lines).first(where: { $0.newNumber == number }) else { return nil }
        return ReviewLocation(file: file, line: line, isOldSide: false)
    }

    static func existingDiscussion(for assessment: PullRequestAIReview.Assessment, threads: [ReviewThread]) -> ReviewThread? {
        let available = threads.filter { !$0.isResolved && !$0.isSystemOnly }
        if let id = assessment.discussionID, let existing = available.first(where: { $0.id == id }) {
            return existing
        }
        return available.first { thread in
            thread.notes.contains { $0.body.contains(":\(issueKey(assessment)) -->") }
                || (thread.filePath == assessment.file && thread.line == assessment.line
                    && thread.notes.contains { $0.body.contains(":\(assessment.area.rawValue) -->") && $0.body.contains(assessment.summary) })
        }
    }

    static func body(for assessment: PullRequestAIReview.Assessment, head: String) -> String {
        let location = assessment.file.map {
            "\n\n位置：`\($0)\(assessment.line.map { ":\($0)" } ?? "")`"
        } ?? ""
        return "\(marker(head: head, area: issueKey(assessment)))\n### \(assessment.summary)\n\n**Grove AI Review · \(assessment.area.displayName)**\n\n\(assessment.evidence ?? "")\(location)\n\n审查提交：`\(head)`"
    }

}
