import Foundation
import XCTest
@testable import Grove

final class AIUsageLogTests: XCTestCase {
    func testRequestLifecycleKeepsUsageWhenOutputValidationOrHTTPFails() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let log = AIUsageLog(directory: folder)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [UsageLogURLProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        for mode in ["成功", "格式错误", "服务错误", "超时", "取消"] {
            do {
                let _: [String: Int] = try await AIGenerationRunner.run(
                    prompt: "不应出现在日志里的源码正文",
                    schema: "不应出现在日志里的完整格式",
                    service: .api(.init(baseURL: "https://日志测试.invalid/\(mode)", model: "glm-5.3-flash",
                                        apiKey: "不应出现在日志里的密钥", thinking: .disabled)),
                    in: folder, operation: "PR审查",
                    context: .init(trigger: "自动", pullRequestNumber: 811, head: "测试版本"),
                    log: log, session: session
                ) { try JSONDecoder().decode([String: Int].self, from: $0) }
                XCTAssertEqual(mode, "成功")
            } catch {
                XCTAssertNotEqual(mode, "成功")
            }
        }
        let files = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
        XCTAssertEqual(files.count, 5)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let records = try files.map { try decoder.decode(AIUsageLog.Record.self, from: Data(contentsOf: $0)) }
        XCTAssertEqual(records.filter { $0.result == "成功" }.count, 1)
        XCTAssertEqual(records.filter { $0.result == "失败" }.count, 3)
        XCTAssertEqual(records.filter { $0.result == "已取消" }.count, 1)
        let invalid = try XCTUnwrap(records.first { $0.failureReason == "模型输出未通过格式或内容校验" })
        XCTAssertEqual(invalid.usage?.totalTokens, 120)
        XCTAssertEqual(invalid.usage?.cachedTokens, 20)
        XCTAssertEqual(invalid.usage?.reasoningTokens, 5)
        XCTAssertEqual(invalid.httpStatus, 200)
        XCTAssertEqual(records.first { $0.httpStatus == 500 }?.usageState, "未知（服务未返回用量）")
        for record in records {
            XCTAssertEqual(record.context.trigger, "自动")
            XCTAssertEqual(record.context.pullRequestNumber, 811)
            XCTAssertEqual(record.context.head, "测试版本")
            XCTAssertEqual(record.thinking, "关闭思考")
            XCTAssertNotNil(record.finishedAt)
            XCTAssertNotNil(record.durationMilliseconds)
            XCTAssertGreaterThan(record.requestBytes ?? 0, record.promptBytes)
        }
        for file in files {
            let text = try String(contentsOf: file, encoding: .utf8)
            XCTAssertFalse(text.contains("不应出现在日志里"))
            XCTAssertFalse(text.contains("模型正文保密"))
        }
    }

    func testRetentionRemovesOnlyOlderThan72HoursAndPersistsStartedCalls() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let log = AIUsageLog(directory: folder)
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        var ids: [UUID] = []
        for age in [AIUsageLog.retention + 1, AIUsageLog.retention, 60] {
            let startedAt = now.addingTimeInterval(-age)
            let id = await log.begin(.init(startedAt: startedAt, operation: "PR审查", context: .init(),
                                          repository: "测试仓库", provider: "兼容API", model: "测试模型",
                                          promptBytes: 10, schemaBytes: 10))
            await log.finish(id, now: startedAt)
            ids.append(id)
        }
        // 破损文件和其他类型文件不能阻止正常日志过期清理。
        try Data("损坏".utf8).write(to: folder.appendingPathComponent("\(UUID()).json"))
        try Data("保留".utf8).write(to: folder.appendingPathComponent("其他文件.txt"))
        await log.cleanup(now: now)
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.appendingPathComponent("\(ids[0]).json").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: folder.appendingPathComponent("\(ids[1]).json").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: folder.appendingPathComponent("\(ids[2]).json").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: folder.appendingPathComponent("其他文件.txt").path))
        let pending = await log.begin(.init(startedAt: now, operation: "PR审查", context: .init(),
                                           repository: "测试仓库", provider: "兼容API", model: "测试模型",
                                           promptBytes: 10, schemaBytes: 10))
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let record = try decoder.decode(AIUsageLog.Record.self, from: Data(contentsOf: folder.appendingPathComponent("\(pending).json")))
        XCTAssertEqual(record.result, "进行中")
        XCTAssertNil(record.finishedAt)
        XCTAssertNil(record.usage)
    }

    func testPartialUsagePreservesUnknownFieldsAndRejectsInvalidCounts() {
        let data = Data(#"{"usage":{"prompt_tokens":17,"completion_tokens":true,"total_tokens":-1}}"#.utf8)
        let usage = AIUsageLog.Usage.from(data)
        XCTAssertEqual(usage?.inputTokens, 17)
        XCTAssertNil(usage?.outputTokens)
        XCTAssertNil(usage?.totalTokens)
        XCTAssertNil(usage?.cachedTokens)
        XCTAssertNil(AIUsageLog.Usage.from(Data(#"{"choices":[]}"#.utf8)))
    }
}

private final class UsageLogURLProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let mode = request.url?.pathComponents.dropFirst().first ?? ""
        if mode == "超时" || mode == "取消" {
            client?.urlProtocol(self, didFailWithError: URLError(mode == "超时" ? .timedOut : .cancelled))
            return
        }
        let content = mode == "格式错误" ? "模型正文保密" : "{\"结果\":1}"
        let object: [String: Any] = mode == "服务错误"
            ? ["error": ["message": "不应出现在日志里的服务错误正文"]]
            : ["choices": [["message": ["content": content]]],
               "usage": ["prompt_tokens": 100, "completion_tokens": 20, "total_tokens": 120,
                         "prompt_tokens_details": ["cached_tokens": 20],
                         "completion_tokens_details": ["reasoning_tokens": 5]]]
        do {
            let data = try JSONSerialization.data(withJSONObject: object)
            let response = HTTPURLResponse(url: request.url!, statusCode: mode == "服务错误" ? 500 : 200,
                                           httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}
