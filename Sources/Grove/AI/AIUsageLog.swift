import Foundation
import OSLog

/// 只记录调用元数据与服务返回的用量，不保存密钥、提示词或模型正文。
actor AIUsageLog {
    static let shared = AIUsageLog()
    static let directory = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/Grove/AI", isDirectory: true)
    static let retention: TimeInterval = 3 * 24 * 60 * 60

    struct Context: Sendable, Codable {
        var trigger = "手动"
        var pullRequestNumber: Int?
        var head: String?

        enum CodingKeys: String, CodingKey {
            case trigger = "触发方式", pullRequestNumber = "PR编号", head = "提交版本"
        }
    }

    struct Usage: Sendable, Codable, Equatable {
        var inputTokens: Int?
        var outputTokens: Int?
        var totalTokens: Int?
        var cachedTokens: Int?
        var reasoningTokens: Int?

        enum CodingKeys: String, CodingKey {
            case inputTokens = "输入token", outputTokens = "输出token", totalTokens = "总token"
            case cachedTokens = "缓存命中token", reasoningTokens = "思考token"
        }

        static func from(_ data: Data) -> Usage? {
            guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let usage = object["usage"] as? [String: Any] else { return nil }
            func count(_ value: Any?) -> Int? {
                guard let value, JSONSerialization.isValidJSONObject([value]),
                      let bytes = try? JSONSerialization.data(withJSONObject: [value]),
                      let number = try? JSONDecoder().decode([Int].self, from: bytes).first,
                      number >= 0 else { return nil }
                return number
            }
            let input = usage["prompt_tokens_details"] as? [String: Any]
            let output = usage["completion_tokens_details"] as? [String: Any]
            return Usage(inputTokens: count(usage["prompt_tokens"]),
                         outputTokens: count(usage["completion_tokens"]),
                         totalTokens: count(usage["total_tokens"]),
                         cachedTokens: count(input?["cached_tokens"]),
                         reasoningTokens: count(output?["reasoning_tokens"]))
        }
    }

    struct Record: Sendable, Codable {
        var id = UUID()
        var startedAt: Date
        var finishedAt: Date?
        var operation: String
        var context: Context
        var repository: String
        var provider: String
        var model: String
        var thinking: String?
        var promptBytes: Int
        var schemaBytes: Int
        var requestBytes: Int?
        var responseBytes: Int?
        var durationMilliseconds: Int?
        var httpStatus: Int?
        var usage: Usage?
        var usageState = "未知（服务尚未返回用量）"
        var result = "进行中"
        var failureReason: String?

        enum CodingKeys: String, CodingKey {
            case id = "调用ID", startedAt = "开始时间", finishedAt = "结束时间"
            case operation = "操作", context = "审查上下文", repository = "仓库"
            case provider = "服务类型", model = "模型", thinking = "思考设置"
            case promptBytes = "提示词字节数", schemaBytes = "输出格式字节数"
            case requestBytes = "HTTP请求字节数", responseBytes = "响应字节数"
            case durationMilliseconds = "耗时毫秒", httpStatus = "HTTP状态码"
            case usage = "服务返回用量", usageState = "用量状态", result = "结果", failureReason = "失败原因"
        }
    }

    private let folder: URL
    private var active: [UUID: Record] = [:]
    private var maintenance: Task<Void, Never>?
    private let logger = Logger(subsystem: "local.jamie.Grove", category: "AI调用日志")

    init(directory: URL = AIUsageLog.directory) { folder = directory }

    func startMaintenance() {
        guard maintenance == nil else { return }
        maintenance = Task { [weak self] in
            while !Task.isCancelled {
                await self?.cleanup()
                do { try await Task.sleep(for: .seconds(3600)) } catch { return }
            }
        }
    }

    func begin(_ record: Record) -> UUID {
        cleanup(now: record.startedAt)
        active[record.id] = record
        persist(record)
        return record.id
    }

    func sent(_ id: UUID, bytes: Int) {
        guard var record = active[id] else { return }
        record.requestBytes = bytes
        active[id] = record
        persist(record)
    }

    func response(_ id: UUID, data: Data, status: Int) {
        guard var record = active[id] else { return }
        record.responseBytes = data.count
        record.httpStatus = status
        record.usage = Usage.from(data)
        record.usageState = record.usage == nil ? "未知（服务未返回用量）" : "服务返回值（缺失字段为未知）"
        active[id] = record
        persist(record)
    }

    func finish(_ id: UUID, error: (any Error)? = nil, now: Date = Date()) {
        guard var record = active.removeValue(forKey: id) else { return }
        record.finishedAt = now
        record.durationMilliseconds = Int(max(0, now.timeIntervalSince(record.startedAt)) * 1000)
        if let error {
            let cancelled = error is CancellationError || (error as? URLError)?.code == .cancelled
            record.result = cancelled ? "已取消" : "失败"
            switch error {
            case AIAPIError.timeout, CodexGenerationError.timeout: record.failureReason = "请求超时"
            case AIAPIError.invalidConfiguration: record.failureReason = "API配置无效"
            case AIAPIError.requestFailed: record.failureReason = "服务拒绝请求（见HTTP状态码）"
            case AIAPIError.invalidResponse: record.failureReason = "服务响应无法读取"
            case CodexGenerationError.invalidOutput, CodexGenerationError.emptyOutput, is DecodingError:
                record.failureReason = "模型输出未通过格式或内容校验"
            default: record.failureReason = cancelled ? "调用已取消" : "调用失败"
            }
        } else {
            record.result = "成功"
        }
        persist(record)
    }

    // ponytail: 三天内调用量较小时逐条读取日志清理；高频场景可改为按时间分目录。
    func cleanup(now: Date = Date()) {
        do {
            guard FileManager.default.fileExists(atPath: folder.path) else { return }
            let files = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            for file in files where file.pathExtension == "json" && UUID(uuidString: file.deletingPathExtension().lastPathComponent) != nil {
                do {
                    let record = try decoder.decode(Record.self, from: Data(contentsOf: file))
                    if record.startedAt < now.addingTimeInterval(-Self.retention), active[record.id] == nil {
                        try FileManager.default.removeItem(at: file)
                    }
                } catch {
                    logger.error("清理单条AI调用日志失败，继续处理其他日志。")
                }
            }
        } catch {
            logger.error("清理AI调用日志失败，请检查日志目录权限或文件完整性。")
        }
    }

    func openDirectory() throws -> URL {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        cleanup()
        return folder
    }

    private func persist(_ record: Record) {
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            try encoder.encode(record).write(to: folder.appendingPathComponent("\(record.id).json"), options: .atomic)
        } catch {
            logger.error("写入AI调用日志失败，请检查日志目录权限或可用空间。")
        }
    }
}
