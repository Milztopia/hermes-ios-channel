import Foundation

// MARK: - ToolEvent

struct ToolEvent: Codable {
    var tool: String
    var preview: String?
    var duration: Double?
    var error: String?
    var toolCallId: String?
    var output: String?
    var resultSummary: String?
    // Set true when a tool.completed event arrives. The server doesn't always
    // send a result_summary, so completion can't be inferred from that alone.
    var completed: Bool?

    init(tool: String, preview: String? = nil, duration: Double? = nil,
         error: String? = nil, toolCallId: String? = nil,
         output: String? = nil, resultSummary: String? = nil,
         completed: Bool? = nil) {
        self.tool = tool; self.preview = preview; self.duration = duration
        self.error = error; self.toolCallId = toolCallId
        self.output = output; self.resultSummary = resultSummary
        self.completed = completed
    }
}

enum ToolActivityPresenter {
    static func statusText(for tool: ToolEvent) -> String {
        let preview = cleanPreview(tool.preview)
        switch tool.tool {
        case "web_search", "search_web":
            return preview.map { "Searching the web for \($0)..." } ?? "Searching the web..."
        case "web_extract", "web_fetch", "fetch_url", "extract_url":
            return preview.map { "Reading \($0)..." } ?? "Reading web pages..."
        case "send_file":
            return preview.map { "Preparing \($0)..." } ?? "Preparing a file..."
        case "image_generation", "generate_image":
            return preview.map { "Generating an image from \($0)..." } ?? "Generating an image..."
        case "terminal", "shell":
            return "Running a command..."
        default:
            let name = displayName(for: tool.tool)
            return preview.map { "Using \(name): \($0)..." } ?? "Using \(name)..."
        }
    }

    static func completedText(for tool: ToolEvent) -> String {
        switch tool.tool {
        case "web_search", "search_web": return "Searched the web"
        case "web_extract", "web_fetch", "fetch_url", "extract_url": return "Read web pages"
        case "send_file": return "Prepared a file"
        case "image_generation", "generate_image": return "Generated an image"
        case "terminal", "shell": return "Ran a command"
        default: return "Used \(displayName(for: tool.tool))"
        }
    }

    static func rowText(for tool: ToolEvent) -> String {
        if let error = tool.error, !error.isEmpty {
            return "\(completedText(for: tool)) failed"
        }
        if tool.completed == true || tool.resultSummary != nil {
            return completedText(for: tool)
        }
        return statusText(for: tool)
    }

    static func displayName(for toolName: String) -> String {
        let cleaned = toolName.replacingOccurrences(of: "_", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? "tool" : cleaned
    }

    static func cleanPreview(_ value: String?) -> String? {
        guard var text = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !text.isEmpty else { return nil }
        text = text.trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
        if text.count > 72 {
            text = String(text.prefix(69)).trimmingCharacters(in: .whitespacesAndNewlines) + "..."
        }
        return text.isEmpty ? nil : text
    }
}

// MARK: - ApprovalRequest

struct ApprovalRequest: Codable, Identifiable {
    enum RiskLevel: String, Codable { case low, medium, high }
    enum Status: String, Codable { case pending, approved, denied, expired, superseded }

    let id: String
    var runId: String
    var title: String
    var riskLevel: RiskLevel?
    var reason: String?
    var commandPreview: String?
    var toolName: String?
    var createdAt: Date
    var status: Status
    var choices: [String]?

    init(id: String, runId: String, title: String = "Approval Required",
         riskLevel: RiskLevel? = nil, reason: String? = nil,
         commandPreview: String? = nil, toolName: String? = nil,
         status: Status = .pending, choices: [String]? = nil) {
        self.id = id; self.runId = runId; self.title = title
        self.riskLevel = riskLevel; self.reason = reason
        self.commandPreview = commandPreview; self.toolName = toolName
        self.createdAt = Date(); self.status = status; self.choices = choices
    }

    enum CodingKeys: String, CodingKey {
        case id, title, reason, status, choices
        case runId, riskLevel, commandPreview, toolName, createdAt
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        runId = try c.decodeIfPresent(String.self, forKey: .runId) ?? ""
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? "Approval Required"
        riskLevel = try c.decodeIfPresent(RiskLevel.self, forKey: .riskLevel)
        reason = try c.decodeIfPresent(String.self, forKey: .reason)
        commandPreview = try c.decodeIfPresent(String.self, forKey: .commandPreview)
        toolName = try c.decodeIfPresent(String.self, forKey: .toolName)
        choices = try c.decodeIfPresent([String].self, forKey: .choices)
        status = try c.decodeIfPresent(Status.self, forKey: .status) ?? .pending
        if let s = try? c.decodeIfPresent(String.self, forKey: .createdAt) {
            createdAt = ISO8601DateFormatter.parse(s) ?? Date()
        } else {
            createdAt = Date()
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(runId, forKey: .runId)
        try c.encode(title, forKey: .title)
        let iso = ISO8601DateFormatter(); iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        try c.encode(iso.string(from: createdAt), forKey: .createdAt)
        try c.encode(status, forKey: .status)
        try c.encodeIfPresent(riskLevel, forKey: .riskLevel)
        try c.encodeIfPresent(reason, forKey: .reason)
        try c.encodeIfPresent(commandPreview, forKey: .commandPreview)
        try c.encodeIfPresent(toolName, forKey: .toolName)
        try c.encodeIfPresent(choices, forKey: .choices)
    }
}

// MARK: - Run request/response

struct StartRunRequest: Encodable {
    var input: RunInput
    var stream: Bool = true
    var model: String?
    var provider: String?
    var instructions: String?
    var conversationHistory: [HistoryMessage]?
    var tools: [String]?
    // Per-chat toolset override. When nil, the field is omitted and the server
    // uses the universal api_server config. When set, it overrides for this run.
    var enabledToolsets: [String]?
    // Continue the same Hermes session across turns. The gateway's /v1/runs
    // reads session_id from the BODY (the X-Hermes-Session-Id header is ignored
    // on this endpoint). When nil, the server falls back to session_id = run_id
    // and every turn becomes a separate session in state.db — which is why the
    // official desktop app listed each turn as its own conversation. Omitted on
    // the first turn; thereafter we send the chat's stored hermesSessionId.
    var sessionId: String?

    enum CodingKeys: String, CodingKey {
        case input, stream, model, provider, instructions, tools
        case conversationHistory = "conversation_history"
        case enabledToolsets = "enabled_toolsets"
        case sessionId = "session_id"
    }
}

enum RunInput: Encodable {
    case text(String)
    case parts([RunInputPart])

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .text(let s): try c.encode(s)
        case .parts(let p): try c.encode(p)
        }
    }
}

struct RunInputPart: Encodable {
    enum PartType: String, Encodable { case text, image_url }
    var type: PartType
    var text: String?
    var imageUrl: ImageUrl?
    struct ImageUrl: Encodable { var url: String }
    enum CodingKeys: String, CodingKey { case type, text, imageUrl = "image_url" }
}

struct HistoryMessage: Encodable {
    var role: String
    var content: String
}

struct StartRunResponse: Decodable {
    var runId: String
    var status: String?
    enum CodingKeys: String, CodingKey { case runId = "run_id"; case status }
}

// MARK: - WebSource

/// A single search result surfaced on a `web_search` tool.completed event,
/// rendered as a source card under the assistant answer.
struct WebSource: Codable, Identifiable, Hashable {
    var title: String
    var url: String
    var description: String?
    var position: Int?
    var id: String { url }

    enum CodingKeys: String, CodingKey { case title, url, description, position }
}

// MARK: - SentFile

/// A file the agent sent via the `send_file` tool, surfaced on the tool.completed
/// event and rendered as a downloadable file card. `url` is server-relative
/// (e.g. /api/hermes-file/<id>) and resolved against the client base URL.
struct SentFile: Codable, Identifiable, Hashable {
    var id: String
    var name: String
    var size: Int?
    var mime: String?
    var url: String
}

// MARK: - RunEvent

enum RunEvent {
    case messageDelta(runId: String, delta: String)
    case messageComplete(runId: String)
    case toolStarted(runId: String, tool: ToolEvent)
    case toolCompleted(runId: String, toolName: String, toolCallId: String, duration: Double?, resultSummary: String?, sources: [WebSource]?, file: SentFile?, isError: Bool)
    case approvalRequired(runId: String, approval: ApprovalRequest)
    case approvalResolved(runId: String, approvalId: String, status: String)
    case runCompleted(runId: String, output: String?)
    case runFailed(runId: String, error: String)
    case runStopped(runId: String)
    case unknown(type: String)

    static func parse(eventType: String, data: String) -> RunEvent? {
        guard !data.isEmpty, data != "[DONE]" else { return nil }
        guard let raw = data.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: raw) as? [String: Any] else { return nil }

        let rawType = (json["event"] as? String ?? json["type"] as? String ?? eventType)
            .replacingOccurrences(of: ".", with: "_")
        let runId = json["run_id"] as? String ?? json["runId"] as? String ?? ""

        switch rawType {
        case "message_delta":
            return .messageDelta(runId: runId, delta: json["delta"] as? String ?? "")

        case "message_complete":
            return .messageComplete(runId: runId)

        case "tool_started", "tool_start":
            let td = json["tool"] as? [String: Any] ?? json
            let tool = ToolEvent(
                tool: td["tool"] as? String ?? td["name"] as? String ?? "",
                preview: td["preview"] as? String,
                duration: td["duration"] as? Double,
                toolCallId: td["tool_call_id"] as? String ?? td["toolCallId"] as? String,
                resultSummary: td["result_summary"] as? String ?? td["resultSummary"] as? String
            )
            return .toolStarted(runId: runId, tool: tool)

        case "tool_completed", "tool_complete":
            let td = json["tool"] as? [String: Any]
            let toolName = (json["tool"] as? String) ?? td?["tool"] as? String ?? td?["name"] as? String ?? ""
            let tcId = json["tool_call_id"] as? String ?? json["toolCallId"] as? String ?? ""
            let summary = json["result_summary"] as? String ?? json["resultSummary"] as? String
            let duration = json["duration"] as? Double
            // Server sends `error` as a bool (false = ok) or, less commonly, a string.
            let isError = (json["error"] as? Bool == true) || (json["error"] is String)
            // Source-bearing tools (web_search) attach a structured sources list.
            var sources: [WebSource]? = nil
            if let rawSources = json["sources"] as? [[String: Any]] {
                let parsed = rawSources.compactMap { item -> WebSource? in
                    guard let url = item["url"] as? String, !url.isEmpty else { return nil }
                    return WebSource(
                        title: (item["title"] as? String) ?? "",
                        url: url,
                        description: item["description"] as? String,
                        position: item["position"] as? Int
                    )
                }
                if !parsed.isEmpty { sources = parsed }
            }
            // send_file attaches a {id,name,size,mime,url} file descriptor.
            var file: SentFile? = nil
            if let f = json["file"] as? [String: Any],
               let url = f["url"] as? String, !url.isEmpty {
                file = SentFile(
                    id: (f["id"] as? String) ?? url,
                    name: (f["name"] as? String) ?? "file",
                    size: f["size"] as? Int,
                    mime: f["mime"] as? String,
                    url: url
                )
            }
            return .toolCompleted(runId: runId, toolName: toolName, toolCallId: tcId,
                                  duration: duration, resultSummary: summary,
                                  sources: sources, file: file, isError: isError)

        case "approval_required", "approval_request":
            let ad = json["approval"] as? [String: Any] ?? json
            let apr = ApprovalRequest(
                id: ad["id"] as? String ?? UUID().uuidString,
                runId: runId,
                title: ad["title"] as? String ?? "Approval Required",
                riskLevel: (ad["risk_level"] as? String ?? ad["riskLevel"] as? String)
                    .flatMap { ApprovalRequest.RiskLevel(rawValue: $0) },
                reason: ad["reason"] as? String,
                commandPreview: ad["command_preview"] as? String ?? ad["commandPreview"] as? String,
                toolName: ad["tool_name"] as? String ?? ad["toolName"] as? String,
                choices: ad["choices"] as? [String]
            )
            return .approvalRequired(runId: runId, approval: apr)

        case "approval_resolved", "approval_responded":
            let aprId = json["approval_id"] as? String ?? json["approvalId"] as? String ?? ""
            return .approvalResolved(runId: runId, approvalId: aprId, status: json["status"] as? String ?? "")

        case "run_completed":
            return .runCompleted(runId: runId, output: json["output"] as? String)

        case "run_failed":
            return .runFailed(runId: runId, error: json["error"] as? String ?? "Unknown error")

        case "run_stopped", "run_cancelled":
            return .runStopped(runId: runId)

        default:
            return .unknown(type: rawType)
        }
    }
}

// MARK: - Tool definition

struct HermesToolDefinition: Identifiable, Decodable {
    var name: String            // toolset key, e.g. "web"
    var label: String?          // display label, e.g. "🔍 Web Search & Scraping"
    var description: String?    // member tools / hint
    var tools: [String]         // member tool names
    var requirements: [String]  // missing env vars / services for unavailable toolsets
    var available: Bool         // requirements satisfied on the server
    var enabled: Bool           // currently in the universal api_server selection
    var required: Bool
    var id: String { name }

    enum CodingKeys: String, CodingKey { case name, label, description, tools, requirements, available, enabled, required }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decode(String.self, forKey: .name)
        label = try? c.decodeIfPresent(String.self, forKey: .label)
        description = try? c.decodeIfPresent(String.self, forKey: .description)
        tools = (try? c.decodeIfPresent([String].self, forKey: .tools)) ?? []
        requirements = (try? c.decodeIfPresent([String].self, forKey: .requirements)) ?? []
        available = (try? c.decodeIfPresent(Bool.self, forKey: .available)) ?? true
        enabled = (try? c.decodeIfPresent(Bool.self, forKey: .enabled)) ?? false
        required = (try? c.decodeIfPresent(Bool.self, forKey: .required)) ?? false
    }
}

// MARK: - UI Settings

struct UISettings: Codable {
    var systemPrompt: String
    var contextLimit: Int
    var selectedProvider: String
    var selectedModel: String
    var ttsVoice: String
    // Kept for compatibility with existing server settings files. Voice mode
    // always speaks in the iOS app.
    var autoSpeak: Bool
    var vadSilenceMs: Int
    var fontSize: String
    var messageDensity: String
    var backgroundNotifications: Bool

    init(systemPrompt: String, contextLimit: Int, selectedProvider: String, selectedModel: String,
         ttsVoice: String, autoSpeak: Bool, vadSilenceMs: Int,
         fontSize: String, messageDensity: String, backgroundNotifications: Bool) {
        self.systemPrompt = systemPrompt
        self.contextLimit = contextLimit
        self.selectedProvider = selectedProvider
        self.selectedModel = selectedModel
        self.ttsVoice = ttsVoice
        self.autoSpeak = autoSpeak
        self.vadSilenceMs = vadSilenceMs
        self.fontSize = fontSize
        self.messageDensity = messageDensity
        self.backgroundNotifications = backgroundNotifications
    }

    enum CodingKeys: String, CodingKey {
        case systemPrompt, contextLimit, selectedProvider, selectedModel, ttsVoice, autoSpeak
        case vadSilenceMs, fontSize, messageDensity, backgroundNotifications
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = Self.defaults
        systemPrompt = (try? c.decodeIfPresent(String.self, forKey: .systemPrompt)) ?? defaults.systemPrompt
        contextLimit = (try? c.decodeIfPresent(Int.self, forKey: .contextLimit)) ?? defaults.contextLimit
        selectedProvider = (try? c.decodeIfPresent(String.self, forKey: .selectedProvider)) ?? defaults.selectedProvider
        selectedModel = (try? c.decodeIfPresent(String.self, forKey: .selectedModel)) ?? defaults.selectedModel
        ttsVoice = (try? c.decodeIfPresent(String.self, forKey: .ttsVoice)) ?? defaults.ttsVoice
        autoSpeak = (try? c.decodeIfPresent(Bool.self, forKey: .autoSpeak)) ?? defaults.autoSpeak
        vadSilenceMs = (try? c.decodeIfPresent(Int.self, forKey: .vadSilenceMs)) ?? defaults.vadSilenceMs
        fontSize = (try? c.decodeIfPresent(String.self, forKey: .fontSize)) ?? defaults.fontSize
        messageDensity = (try? c.decodeIfPresent(String.self, forKey: .messageDensity)) ?? defaults.messageDensity
        backgroundNotifications = (try? c.decodeIfPresent(Bool.self, forKey: .backgroundNotifications)) ?? defaults.backgroundNotifications
    }

    static var defaults: UISettings {
        UISettings(systemPrompt: "", contextLimit: 0, selectedProvider: "", selectedModel: "",
                   ttsVoice: "george", autoSpeak: true, vadSilenceMs: 1200,
                   fontSize: "medium", messageDensity: "comfortable", backgroundNotifications: true)
    }
}

// MARK: - Available model

struct AvailableModel: Identifiable, Decodable {
    var id: String
    var name: String
    var provider: String?
}

struct AvailableModelProvider: Identifiable, Decodable {
    var id: String
    var name: String
    var models: [AvailableModel]
    var defaultModel: String?
    var authenticated: Bool?
}

struct ModelsResponse: Decodable {
    var models: [AvailableModel]
    var `default`: String
    var defaultProvider: String?
    var providers: [AvailableModelProvider]?
}

struct AvailableVoice: Identifiable, Decodable {
    var id: String
    var name: String
    var supported: Bool
    var reason: String?
}

struct VoicesResponse: Decodable {
    var voices: [AvailableVoice]
    var `default`: String
}

// MARK: - Channel capabilities

struct ChannelCapabilities: Decodable {
    var brain: Brain
    var voice: Voice
    var image: ImageCapability

    struct Brain: Decodable {
        var available: Bool
        var defaultModel: String
        var defaultProvider: String?
        var models: [AvailableModel]
        var providers: [AvailableModelProvider]?
        var required: Bool
    }

    struct Voice: Decodable {
        var hermesTtsAvailable: Bool
        var hermesSttAvailable: Bool
        var iosLocalFallback: Bool
        var defaultVoice: String?
        var voices: [AvailableVoice]?
    }

    struct ImageCapability: Decodable {
        var available: Bool
        var required: Bool
    }
}
