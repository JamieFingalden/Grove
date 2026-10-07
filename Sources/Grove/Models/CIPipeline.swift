import SwiftUI

/// CI 状态的规范化。两个平台各自的词表都折到这一套上，
/// 展示层只认这套，不用每个页面都写一遍映射。
enum CIStatus: String, Sendable, Hashable {
    case pending
    case running
    case success
    case failed
    case canceled
    case skipped
    case manual

    /// SF Symbol。列表里靠图标 + 颜色双通道区分状态。
    var systemImage: String {
        switch self {
        case .pending: "clock"
        case .running: "arrow.triangle.2.circlepath"
        case .success: "checkmark.circle.fill"
        case .failed: "xmark.circle.fill"
        case .canceled: "minus.circle.fill"
        case .skipped: "slash.circle"
        case .manual: "hand.tap"
        }
    }

    var tint: Color {
        switch self {
        case .pending: .secondary
        case .running: .blue
        case .success: .green
        case .failed: .red
        case .canceled: .orange
        case .skipped: .secondary
        case .manual: Color(nsColor: .systemIndigo)
        }
    }

    var label: String {
        switch self {
        case .pending: "等待中"
        case .running: "运行中"
        case .success: "已通过"
        case .failed: "已失败"
        case .canceled: "已取消"
        case .skipped: "已跳过"
        case .manual: "待手动触发"
        }
    }

    /// 是否已经到终态（不会再自己变）。决定列表要不要自动轮询、
    /// 重试/取消按钮的可用性。
    var isFinal: Bool {
        switch self {
        case .success, .failed, .canceled, .skipped: true
        case .pending, .running, .manual: false
        }
    }

    /// GitLab 流水线/任务的状态词表。老版本（13.x）会出现的
    /// `created` / `waiting_for_resource` / `preparing` / `scheduled`
    /// 全都算「还没跑起来」。
    static func gitlab(_ raw: String) -> CIStatus {
        switch raw {
        case "running": .running
        case "success": .success
        case "failed": .failed
        case "canceled", "cancelled": .canceled
        case "skipped": .skipped
        case "manual": .manual
        default: .pending
        }
    }

    /// GitHub Actions 的 run/job 状态。`status` 是阶段（queued /
    /// in_progress / completed），`conclusion` 是 completed 后的结果。
    static func github(status: String, conclusion: String?) -> CIStatus {
        switch status {
        case "queued", "requested", "waiting", "pending": return .pending
        case "in_progress": return .running
        default: break
        }
        return switch conclusion ?? "" {
        case "success", "neutral": .success
        case "failure", "timed_out", "startup_failure", "action_required": .failed
        case "cancelled": .canceled
        case "skipped": .skipped
        default: .pending
        }
    }
}

/// 一条流水线（GitLab pipeline / GitHub workflow run）。
struct CIPipeline: Identifiable, Hashable, Sendable {
    var id: Int
    var status: CIStatus
    /// 跑的分支。
    var ref: String
    var sha: String
    /// 触发标题（GitHub 有 displayTitle；GitLab 列表接口不带）。
    var title: String?
    /// 触发者（GitLab 列表接口不带用户；GitHub 用事件名代替）。
    var trigger: String?
    var createdAt: Date?
    var duration: TimeInterval?
    var webURL: String?

    var shortSHA: String { String(sha.prefix(8)) }
}

/// 流水线里的一个任务（GitLab job / GitHub job）。
struct CIJob: Identifiable, Hashable, Sendable {
    var id: Int
    var name: String
    /// 所属阶段。GitHub Actions 没有阶段概念，留空让界面归到「任务」一组。
    var stage: String?
    var status: CIStatus
    var duration: TimeInterval?
    /// 进 runner 之前排了多久（GitLab 提供）。自建实例 runner 不够用时长这东西。
    var queuedDuration: TimeInterval?
    var allowFailure: Bool
    var webURL: String?
}

/// 把流水线列表折成「分支 → 最新状态」。列表本身是最新在前，
/// 每个分支取第一条就是它最新一条流水线的状态。
/// 侧边栏工作树行的 CI 小点、推送后的盯梢都用它。
enum CIPipelineIndex {
    /// 本次提交的所有已出现流水线结束后才返回结果，旧提交不能代表本次推送。
    static func completedStatus(_ pipelines: [CIPipeline], ref: String, sha: String) -> CIStatus? {
        guard !sha.isEmpty else { return nil }
        let matching = pipelines.filter { $0.ref == ref && $0.sha == sha }
        guard !matching.isEmpty, matching.allSatisfy({ $0.status.isFinal }) else { return nil }
        if matching.contains(where: { $0.status == .failed }) { return .failed }
        if matching.contains(where: { $0.status == .canceled }) { return .canceled }
        return matching.contains(where: { $0.status == .success }) ? .success : .skipped
    }

    static func latestStatusByRef(_ pipelines: [CIPipeline]) -> [String: CIStatus] {
        var result: [String: CIStatus] = [:]
        for pipeline in pipelines where !pipeline.ref.isEmpty {
            if result[pipeline.ref] == nil {
                result[pipeline.ref] = pipeline.status
            }
        }
        return result
    }
}

/// 展示用的格式化。集中在这里，列表、详情、日志共用一份。
enum CIFormat {
    /// 4 分 3 秒 / 1 时 2 分。nil 或不足 1 秒显示 「—」。
    static func duration(_ seconds: TimeInterval?) -> String {
        guard let seconds, seconds >= 1 else { return "—" }
        let total = Int(seconds)
        let hours = total / 3600
        let minutes = total % 3600 / 60
        let secs = total % 60
        if hours > 0 { return "\(hours) 时 \(minutes) 分" }
        if minutes > 0 { return "\(minutes) 分 \(secs) 秒" }
        return "\(secs) 秒"
    }

    /// RelativeDateTimeFormatter 不是 Sendable（Foundation 没标）。配置完
    /// 只读不改，装进 @unchecked Sendable 的盒子共享一份，色每行建一次。
    private final class RelativeFormatterBox: @unchecked Sendable {
        let formatter: RelativeDateTimeFormatter = {
            let formatter = RelativeDateTimeFormatter()
            formatter.unitsStyle = .abbreviated
            return formatter
        }()
    }
    private static let box = RelativeFormatterBox()

    /// 「3 分钟前」。
    static func relative(_ date: Date?) -> String {
        guard let date else { return "—" }
        return box.formatter.localizedString(for: date, relativeTo: Date())
    }
}

/// CI 日志清洗：剥 ANSI 转义序列（颜色、光标移动、清行），归一换行。
/// Runner 日志里几乎必有这些控制符，直接上屏会看到大片乱码。
enum CILog {
    static func plain(_ raw: String) -> String {
        var text = raw.replacingOccurrences(of: "\r\n", with: "\n")
        // 孤立的 \r 是进度条覆盖行（docker pull 之类）——按换行处理。
        text = text.replacingOccurrences(of: "\r", with: "\n")
        // CSI 序列：ESC [ … 终结字母。（字符类里的 / 要转义，否则会把正则提前闭合）
        text = text.replacing(/\x1B\[[0-9;:?]*[ -\/]*[@-~]/, with: "")
        // OSC 序列（窗口标题之类）：ESC ] … BEL 或 ST。
        text = text.replacing(/\x1B\][^\x07\x1B]*(?:\x07|\x1B\\)/, with: "")
        // 其他单字符转义（ESC M 之类）。
        text = text.replacing(/\x1B[@-Z\\^-_]/, with: "")
        return text
    }

    /// 失败日志里的「疑似病因」：第一处看起来像错误的地方 + 后文几行。
    /// 全本地解析，不依赖平台版本；宁漏勿滥 —— 模式收紧一点，
    /// 把普通输出误报成错误比漏报更烦。
    struct FailureExcerpt: Hashable, Sendable {
        /// 1 起始的行号，用来展示和跳转。
        var lineNumber: Int
        var snippet: String
    }

    /// Regex 不是 Sendable（也没标只读）；装进 @unchecked Sendable 盒子共享一份。
    /// 编译正则不便宜，不能每扫一行日志重编一次。
    private final class ErrorPatternBox: @unchecked Sendable {
        let patterns: [Regex<Substring>] = [
            #/Traceback \(most recent call last\):/#,
            #/\bERROR\b/#,
            #/^\S*(?:Error|Exception):/#,
            #/^panic: /#,
            #/(?:^|\s)FAILED\b/#,
            #/^--- FAIL:/#,
            #/^make\[\d+\]: \*\*\*/#,
            #/^npm ERR!/#
        ]
    }
    private static let errorPatternBox = ErrorPatternBox()

    static func failureExcerpts(lines: [String], limit: Int = 3) -> [FailureExcerpt] {
        var excerpts: [FailureExcerpt] = []
        // 不用 Int.min：第一次 index - lastHit 会溢出 trap。
        var lastHit = -1_000_000_000
        for (index, line) in lines.enumerated() {
            guard excerpts.count < limit else { break }
            // 同一段错误只取头一处（Traceback 后面每行都像错误）。
            guard index - lastHit > 6 else { continue }
            guard line.count < 2000, errorPatternBox.patterns.contains(where: { line.contains($0) }) else { continue }
            lastHit = index
            // 摘错误行 + 后面几行：Python 的异常类型在 Traceback 之后才出现。
            let context = lines[(index + 1)..<min(index + 4, lines.count)]
            let snippet = ([line] + context)
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
                .joined(separator: "\n")
            excerpts.append(FailureExcerpt(
                lineNumber: index + 1,
                snippet: String(snippet.prefix(400))
            ))
        }
        return excerpts
    }

    static func failureExcerpts(inPlainLog log: String, limit: Int = 3) -> [FailureExcerpt] {
        failureExcerpts(lines: log.components(separatedBy: .newlines), limit: limit)
    }
}
