import Foundation
import Security

enum AIGenerationProvider: String, CaseIterable, Identifiable, Sendable {
    case codex
    case api

    var id: String { rawValue }

    var name: String {
        switch self {
        case .codex: "Codex 登录"
        case .api: "OpenAI 兼容 API"
        }
    }
}

struct AIAPIConfiguration: Sendable, Equatable {
    var baseURL: String
    var model: String
    var apiKey: String

    private var rootURL: URL? {
        let value = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard var url = URL(string: value),
              let scheme = url.scheme?.lowercased(),
              scheme == "https" || scheme == "http" else {
            return nil
        }
        if url.path.lowercased().hasSuffix("/chat/completions") {
            url.deleteLastPathComponent()
            url.deleteLastPathComponent()
        }
        return url
    }

    var endpoint: URL? {
        guard !model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              var url = rootURL else {
            return nil
        }
        url.append(path: "chat/completions")
        return url
    }

    var modelsEndpoint: URL? {
        guard !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              var url = rootURL else {
            return nil
        }
        url.append(path: "models")
        return url
    }
}

enum AIGenerationService: Sendable {
    case codex(model: AIGenerationModel, reasoningEffort: AIReviewReasoningEffort?)
    case api(AIAPIConfiguration)

    var displayName: String {
        switch self {
        case .codex(let model, _): model.name
        case .api(let configuration): configuration.model
        }
    }
}

enum AIGenerationRunner {
    static func run(
        prompt: String,
        schema: String,
        service: AIGenerationService,
        timeout: Double = ProcessRunner.networkTimeout,
        in directory: URL
    ) async throws -> Data {
        switch service {
        case .codex(let model, let reasoningEffort):
            try await CodexRunner.run(
                prompt: prompt,
                schema: schema,
                model: model,
                reasoningEffort: reasoningEffort,
                timeout: timeout,
                in: directory
            )
        case .api(let configuration):
            try await OpenAICompatibleRunner.run(
                prompt: prompt,
                schema: schema,
                configuration: configuration,
                timeout: timeout
            )
        }
    }
}

enum OpenAICompatibleRunner {
    static func listModels(configuration: AIAPIConfiguration) async throws -> [String] {
        let request = try makeModelsRequest(configuration: configuration)
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else { throw AIAPIError.invalidResponse }
            guard (200..<300).contains(http.statusCode) else {
                throw AIAPIError.requestFailed(statusCode: http.statusCode, message: errorMessage(from: data))
            }
            let catalog = try JSONDecoder().decode(ModelsResponse.self, from: data)
            return Array(Set(catalog.data.map(\.id).filter { !$0.isEmpty })).sorted()
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as AIAPIError {
            throw error
        } catch {
            throw AIAPIError.transport(error.localizedDescription)
        }
    }

    static func makeModelsRequest(configuration: AIAPIConfiguration) throws -> URLRequest {
        guard let url = configuration.modelsEndpoint else { throw AIAPIError.invalidConfiguration }
        var request = URLRequest(url: url)
        request.setValue(
            "Bearer \(configuration.apiKey.trimmingCharacters(in: .whitespacesAndNewlines))",
            forHTTPHeaderField: "Authorization"
        )
        return request
    }
    static func run(
        prompt: String,
        schema: String,
        configuration: AIAPIConfiguration,
        timeout: Double
    ) async throws -> Data {
        let request = try makeRequest(
            prompt: prompt,
            schema: schema,
            configuration: configuration,
            timeout: timeout
        )
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw AIAPIError.invalidResponse
            }
            guard (200..<300).contains(http.statusCode) else {
                throw AIAPIError.requestFailed(
                    statusCode: http.statusCode,
                    message: errorMessage(from: data)
                )
            }
            let decoded = try? JSONDecoder().decode(Response.self, from: data)
            guard let content = decoded?.choices.first?.message.content,
                  !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw AIAPIError.invalidResponse
            }
            return Data(jsonText(from: content).utf8)
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as AIAPIError {
            throw error
        } catch let error as URLError where error.code == .timedOut {
            throw AIAPIError.timeout(seconds: Int(timeout.rounded()))
        } catch {
            throw AIAPIError.transport(error.localizedDescription)
        }
    }

    static func makeRequest(
        prompt: String,
        schema: String,
        configuration: AIAPIConfiguration,
        timeout: Double
    ) throws -> URLRequest {
        guard let url = configuration.endpoint else { throw AIAPIError.invalidConfiguration }
        let instructions = """
        \(prompt)

        只输出一个符合以下 JSON Schema 的 JSON 对象，不要使用 Markdown 代码块，也不要添加解释：
        \(schema)
        """
        let body = RequestBody(
            model: configuration.model.trimmingCharacters(in: .whitespacesAndNewlines),
            messages: [.init(role: "user", content: instructions)]
        )
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = timeout
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(
            "Bearer \(configuration.apiKey.trimmingCharacters(in: .whitespacesAndNewlines))",
            forHTTPHeaderField: "Authorization"
        )
        request.httpBody = try JSONEncoder().encode(body)
        return request
    }

    private struct RequestBody: Encodable {
        struct Message: Encodable {
            var role: String
            var content: String
        }

        var model: String
        var messages: [Message]
    }

    private struct Response: Decodable {
        struct Choice: Decodable {
            struct Message: Decodable { var content: String? }
            var message: Message
        }

        var choices: [Choice]
    }

    private struct ErrorResponse: Decodable {
        struct APIError: Decodable { var message: String? }
        var error: APIError?
    }

    private struct ModelsResponse: Decodable {
        struct Model: Decodable { var id: String }
        var data: [Model]
    }

    private static func errorMessage(from data: Data) -> String {
        if let message = (try? JSONDecoder().decode(ErrorResponse.self, from: data))?.error?.message,
           !message.isEmpty {
            return message
        }
        let text = String(decoding: data, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? "服务没有返回错误详情。" : CommitPromptBuilder.limited(text, byteLimit: 2_000)
    }

    private static func jsonText(from content: String) -> String {
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("```") else { return trimmed }
        let lines = trimmed.components(separatedBy: .newlines)
        guard lines.count >= 3, lines.last?.trimmingCharacters(in: .whitespaces).hasPrefix("```") == true else {
            return trimmed
        }
        return lines.dropFirst().dropLast().joined(separator: "\n")
    }
}

enum AIAPIError: LocalizedError, Sendable, Equatable {
    case invalidConfiguration
    case timeout(seconds: Int)
    case requestFailed(statusCode: Int, message: String)
    case invalidResponse
    case transport(String)

    var isTimeout: Bool {
        if case .timeout = self { return true }
        return false
    }

    var errorDescription: String? {
        switch self {
        case .invalidConfiguration:
            "请在设置中填写有效的 API 地址、模型和 API 密钥。"
        case .timeout(let seconds):
            "AI API 在 \(seconds) 秒内没有返回，请检查网络、服务地址或稍后重试。"
        case .requestFailed(let statusCode, let message):
            "AI API 请求失败（HTTP \(statusCode)）：\(message)"
        case .invalidResponse:
            "AI API 返回的内容无法读取为 Grove 所需的 JSON。请确认所选模型支持文本生成后重试。"
        case .transport(let message):
            "无法连接 AI API：\(message)"
        }
    }
}

enum AIGenerationFailure {
    static func isTimeout(_ error: Error) -> Bool {
        (error as? CodexGenerationError)?.isTimeout == true
            || (error as? AIAPIError)?.isTimeout == true
    }
}

enum AIAPIKeychain {
    private static let service = "com.grove.app.ai"
    private static let account = "openai-compatible-api-key"

    static func read() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    static func save(_ value: String) throws {
        let data = Data(value.utf8)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        let attributes = [kSecValueData as String: data]
        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var item = query
            item[kSecValueData as String] = data
            let addStatus = SecItemAdd(item as CFDictionary, nil)
            guard addStatus == errSecSuccess else { throw AIAPIKeychainError(status: addStatus) }
        } else if status != errSecSuccess {
            throw AIAPIKeychainError(status: status)
        }
    }

    static func remove() throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw AIAPIKeychainError(status: status)
        }
    }
}

private struct AIAPIKeychainError: LocalizedError {
    var status: OSStatus

    var errorDescription: String? {
        "无法保存 API 密钥到 macOS 钥匙串（错误码 \(status)）。"
    }
}
