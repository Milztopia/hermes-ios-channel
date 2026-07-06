import Foundation

// MARK: - HermesClient

final class HermesClient: Sendable {
    let baseURL: URL
    private let apiKey: String
    private let session: URLSession

    init(baseURL: URL, apiKey: String) {
        self.baseURL = baseURL
        self.apiKey = apiKey
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 600
        self.session = URLSession(configuration: config)
    }

    // MARK: - Health

    func health() async throws {
        _ = try await get("/api/chats") as [UiChat]
    }

    // MARK: - Chats

    func listChats(updatedWithinDays days: Int? = nil) async throws -> [UiChat] {
        if let days {
            return try await get("/api/chats?updated_within_days=\(days)")
        }
        return try await get("/api/chats")
    }

    func createChat(id: String, title: String) async throws -> UiChat {
        try await post("/api/chats", body: ["id": id, "title": title])
    }

    func updateChat(_ chatId: String, changes: [String: Any]) async throws {
        try await patchRaw("/api/chats/\(chatId)", body: changes)
    }

    func deleteChat(_ chatId: String) async throws {
        try await delete("/api/chats/\(chatId)")
    }

    func listTrash() async throws -> [UiChat] {
        try await get("/api/trash")
    }

    func restoreChat(_ chatId: String) async throws -> UiChat {
        try await post("/api/chats/\(chatId)/restore", body: EmptyBody())
    }

    func emptyTrash() async throws {
        try await delete("/api/trash")
    }

    func getMessages(_ chatId: String) async throws -> [ChatMessage] {
        // Decode element-wise and skip any individual message that fails to
        // decode, so one malformed/foreign-shaped row (e.g. written by the web
        // app) never drops the entire chat history.
        let wrapped: [FailableDecodable<ChatMessage>] = try await get("/api/chats/\(chatId)/messages")
        return wrapped.compactMap(\.value)
    }

    func saveMessages(_ chatId: String, messages: [ChatMessage]) async throws {
        let data = try JSONEncoder().encode(messages)
        var req = request(path: "/api/chats/\(chatId)/messages", method: "POST")
        req.httpBody = data
        _ = try await perform(req)
    }

    // MARK: - Projects

    func listProjects() async throws -> [Project] {
        try await get("/api/projects")
    }

    func createProject(name: String, color: String) async throws -> Project {
        try await post("/api/projects", body: ["name": name, "color": color])
    }

    func deleteProject(_ projectId: String) async throws {
        try await delete("/api/projects/\(projectId)")
    }

    // MARK: - Runs

    func startRun(_ body: StartRunRequest, sessionKey: String, sessionId: String?) async throws -> StartRunResponse {
        var req = request(path: "/api/v1/runs", method: "POST")
        // /v1/runs reads session continuity from the BODY, not the header.
        // Carry the session id in both: the body drives session grouping in
        // state.db; the header is kept for parity with other endpoints.
        var runBody = body
        runBody.sessionId = sessionId
        req.httpBody = try JSONEncoder().encode(runBody)
        req.setValue(sessionKey, forHTTPHeaderField: "X-Hermes-Session-Key")
        if let sid = sessionId {
            req.setValue(sid, forHTTPHeaderField: "X-Hermes-Session-Id")
        }
        let (data, _) = try await perform(req)
        return try decoder.decode(StartRunResponse.self, from: data)
    }

    func stopRun(_ runId: String) async throws {
        var req = request(path: "/api/v1/runs/\(runId)/stop", method: "POST")
        req.httpBody = Data()
        _ = try await perform(req)
    }

    func approveRun(_ runId: String, approvalId: String, choice: String) async throws {
        let body = ["approval_id": approvalId, "choice": choice]
        let data = try JSONSerialization.data(withJSONObject: body)
        var req = request(path: "/api/v1/runs/\(runId)/approval", method: "POST")
        req.httpBody = data
        _ = try await perform(req)
    }

    // MARK: - SSE stream request

    func runEventsRequest(runId: String) -> URLRequest {
        request(path: "/api/v1/runs/\(runId)/events", method: "GET")
    }

    // MARK: - Settings

    func getSettings() async throws -> UISettings {
        try await get("/api/ui-settings")
    }

    func saveSettings(_ settings: UISettings) async throws {
        let data = try JSONEncoder().encode(settings)
        var req = request(path: "/api/ui-settings", method: "PUT")
        req.httpBody = data
        _ = try await perform(req)
    }

    // MARK: - Tools

    func listTools() async throws -> [HermesToolDefinition] {
        try await get("/api/tools")
    }

    /// Write the universal toolset selection (api_server platform) to the server.
    func saveTools(enabled: [String]) async throws {
        var req = request(path: "/api/tools", method: "PUT")
        req.httpBody = try JSONSerialization.data(withJSONObject: ["enabled": enabled])
        _ = try await perform(req)
    }

    // MARK: - Models

    func listModels() async throws -> ModelsResponse {
        try await get("/api/models")
    }

    func listVoices() async throws -> VoicesResponse {
        try await get("/api/voices")
    }

    func getChannelCapabilities() async throws -> ChannelCapabilities {
        try await get("/api/channel-capabilities")
    }

    func activateModel(_ model: String) async throws {
        var req = request(path: "/api/model/activate", method: "POST")
        req.httpBody = try JSONEncoder().encode(["model": model])
        // Model loading can take up to 2 minutes — use a long timeout.
        req.timeoutInterval = 180
        let (_, http) = try await perform(req)
        if http.statusCode >= 400 {
            throw HermesError.httpError(http.statusCode, "model activate failed")
        }
    }

    // MARK: - TTS

    func synthesize(text: String, voice: String) async throws -> Data {
        var req = request(path: "/api/tts", method: "POST")
        let body = try JSONEncoder().encode(["text": text, "voice": voice])
        req.httpBody = body
        let (data, _) = try await perform(req)
        return data
    }

    // MARK: - Image generation

    func generateImage(prompt: String) async throws -> String {
        var req = request(path: "/api/image", method: "POST")
        req.httpBody = try JSONEncoder().encode(["prompt": prompt])
        let (data, _) = try await perform(req)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        return json?["url"] as? String ?? json?["image"] as? String ?? ""
    }

    // MARK: - STT (server-side)

    func transcribe(audioData: Data) async throws -> String {
        var req = request(path: "/api/transcribe", method: "POST")
        req.setValue("audio/wav", forHTTPHeaderField: "Content-Type")
        req.httpBody = audioData
        let (data, _) = try await perform(req)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        // The server returns {"transcript": "..."}; accept "text" as a fallback.
        return (json?["transcript"] as? String) ?? (json?["text"] as? String) ?? ""
    }

    // MARK: - PDF extraction

    func extractPDF(_ pdfData: Data) async throws -> String {
        var req = request(path: "/api/extract-pdf", method: "POST")
        req.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        req.httpBody = pdfData
        let (data, _) = try await perform(req)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        return json?["text"] as? String ?? ""
    }

    // MARK: - Internals

    private var decoder: JSONDecoder {
        let d = JSONDecoder()
        d.keyDecodingStrategy = .useDefaultKeys
        return d
    }

    func request(path: String, method: String) -> URLRequest {
        let url = URL(string: path, relativeTo: baseURL)?.absoluteURL ?? baseURL.appendingPathComponent(path)
        var req = URLRequest(url: url)
        req.httpMethod = method
        // API responses must never be served from URLCache. A 404 path that
        // falls through to the SPA returns index.html with ETag/Last-Modified
        // headers, which URLSession would otherwise cache and replay as stale
        // HTML even after the real JSON route exists.
        req.cachePolicy = .reloadIgnoringLocalCacheData
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        // Trim the key: a pasted trailing space/newline makes "Bearer <key> "
        // an illegal HTTP header value, which the upstream proxy rejects.
        let token = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        if !token.isEmpty {
            req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        return req
    }

    private func get<T: Decodable>(_ path: String) async throws -> T {
        let req = request(path: path, method: "GET")
        let (data, _) = try await perform(req)
        return try decoder.decode(T.self, from: data)
    }

    private func getRaw<T: Decodable>(_ path: String) async throws -> T {
        try await get(path)
    }

    private func post<T: Decodable>(_ path: String, body: some Encodable) async throws -> T {
        var req = request(path: path, method: "POST")
        req.httpBody = try JSONEncoder().encode(body)
        let (data, _) = try await perform(req)
        return try decoder.decode(T.self, from: data)
    }

    private func post<T: Decodable>(_ path: String, body: [String: Any]) async throws -> T {
        var req = request(path: path, method: "POST")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, _) = try await perform(req)
        return try decoder.decode(T.self, from: data)
    }

    private func patchRaw(_ path: String, body: [String: Any]) async throws {
        var req = request(path: path, method: "PATCH")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        _ = try await perform(req)
    }

    private func delete(_ path: String) async throws {
        let req = request(path: path, method: "DELETE")
        _ = try await perform(req)
    }

    @discardableResult
    func perform(_ req: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await session.data(for: req)
        guard let http = response as? HTTPURLResponse else {
            throw HermesError.invalidResponse
        }
        guard (200...299).contains(http.statusCode) else {
            let message = String(data: data, encoding: .utf8) ?? "HTTP \(http.statusCode)"
            throw HermesError.httpError(http.statusCode, message)
        }
        return (data, http)
    }
}

// MARK: - Errors

enum HermesError: LocalizedError {
    case invalidResponse
    case httpError(Int, String)
    case notConfigured

    var errorDescription: String? {
        switch self {
        case .invalidResponse: return "Invalid server response"
        case .httpError(let code, let msg): return "Server error \(code): \(msg)"
        case .notConfigured: return "Server not configured"
        }
    }
}

private struct EmptyBody: Encodable {}

// MARK: - FailableDecodable
// Wraps a Decodable element so a failing element in an array decodes to nil
// instead of throwing and failing the whole array. Used to load chat history
// tolerantly (rows may have been written by the web app with a foreign shape).

struct FailableDecodable<T: Decodable>: Decodable {
    let value: T?
    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        value = try? c.decode(T.self)
    }
}
