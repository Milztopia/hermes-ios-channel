import Foundation

// MARK: - Project

struct Project: Identifiable, Codable, Hashable {
    let id: String
    var name: String
    var color: String
    var createdAt: Date

    static let colors = ["blue", "green", "purple", "orange", "red", "pink", "yellow", "gray"]

    enum CodingKeys: String, CodingKey { case id, name, color, createdAt }

    init(id: String, name: String, color: String, createdAt: Date = Date()) {
        self.id = id; self.name = name; self.color = color; self.createdAt = createdAt
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        color = try c.decodeIfPresent(String.self, forKey: .color) ?? "blue"
        let s = try c.decodeIfPresent(String.self, forKey: .createdAt) ?? ""
        createdAt = ISO8601DateFormatter.parse(s) ?? Date()
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(name, forKey: .name)
        try c.encode(color, forKey: .color)
        let iso = ISO8601DateFormatter(); iso.formatOptions = [.withInternetDateTime]
        try c.encode(iso.string(from: createdAt), forKey: .createdAt)
    }
}

// MARK: - UiChat

struct UiChat: Identifiable, Codable, Hashable {
    let id: String
    var title: String
    var pinned: Bool
    var archived: Bool
    var createdAt: Date
    var updatedAt: Date
    var lastMessagePreview: String
    var projectId: String?
    var hermesSessionId: String?
    var modelProvider: String?
    var modelId: String?
    var isTemporary: Bool

    enum CodingKeys: String, CodingKey {
        case id, title, pinned, archived, isTemporary
        case lastMessagePreview = "last_message_preview"
        case projectId = "project_id"
        case hermesSessionId = "hermes_session_id"
        case modelProvider = "model_provider"
        case modelId = "model_id"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }

    // The server sends pinned/archived as integers (0/1); local persistence
    // writes them as Bool. Decode either so the chat list never fails to parse.
    private static func flexibleBool(_ c: KeyedDecodingContainer<CodingKeys>, _ key: CodingKeys) -> Bool? {
        if let b = try? c.decodeIfPresent(Bool.self, forKey: key) { return b }
        if let i = try? c.decodeIfPresent(Int.self, forKey: key) { return i != 0 }
        return nil
    }

    static func withoutInternalMarkers(_ text: String) -> String {
        var cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let markers = ["[VOICE_MODE]", "[WEB_SEARCH_REQUIRED]"]
        var stripped = true
        while stripped {
            stripped = false
            for marker in markers where cleaned.hasPrefix(marker) {
                cleaned.removeFirst(marker.count)
                cleaned = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
                stripped = true
                break
            }
        }
        return cleaned
    }

    init(id: String, title: String, pinned: Bool, archived: Bool,
         createdAt: Date, updatedAt: Date, lastMessagePreview: String,
         projectId: String?, hermesSessionId: String?, modelProvider: String? = nil,
         modelId: String? = nil, isTemporary: Bool) {
        self.id = id; self.title = Self.withoutInternalMarkers(title); self.pinned = pinned; self.archived = archived
        self.createdAt = createdAt; self.updatedAt = updatedAt
        self.lastMessagePreview = Self.withoutInternalMarkers(lastMessagePreview)
        self.projectId = projectId; self.hermesSessionId = hermesSessionId
        self.modelProvider = modelProvider; self.modelId = modelId
        self.isTemporary = isTemporary
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        title = Self.withoutInternalMarkers(try c.decode(String.self, forKey: .title))
        pinned = Self.flexibleBool(c, .pinned) ?? false
        archived = Self.flexibleBool(c, .archived) ?? false
        lastMessagePreview = Self.withoutInternalMarkers((try? c.decodeIfPresent(String.self, forKey: .lastMessagePreview)) ?? "")
        projectId = try? c.decodeIfPresent(String.self, forKey: .projectId)
        hermesSessionId = try? c.decodeIfPresent(String.self, forKey: .hermesSessionId)
        modelProvider = try? c.decodeIfPresent(String.self, forKey: .modelProvider)
        modelId = try? c.decodeIfPresent(String.self, forKey: .modelId)
        isTemporary = Self.flexibleBool(c, .isTemporary) ?? false
        createdAt = ISO8601DateFormatter.parse(try c.decode(String.self, forKey: .createdAt)) ?? Date()
        updatedAt = ISO8601DateFormatter.parse(try c.decode(String.self, forKey: .updatedAt)) ?? Date()
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(title, forKey: .title)
        try c.encode(pinned, forKey: .pinned)
        try c.encode(archived, forKey: .archived)
        try c.encode(lastMessagePreview, forKey: .lastMessagePreview)
        try c.encodeIfPresent(projectId, forKey: .projectId)
        try c.encodeIfPresent(hermesSessionId, forKey: .hermesSessionId)
        try c.encodeIfPresent(modelProvider, forKey: .modelProvider)
        try c.encodeIfPresent(modelId, forKey: .modelId)
        try c.encode(isTemporary, forKey: .isTemporary)
        let iso = ISO8601DateFormatter(); iso.formatOptions = [.withInternetDateTime]
        try c.encode(iso.string(from: createdAt), forKey: .createdAt)
        try c.encode(iso.string(from: updatedAt), forKey: .updatedAt)
    }
}

// MARK: - ChatAttachment

struct ChatAttachment: Codable, Identifiable {
    enum AttachType: String, Codable { case image, file }
    var id: String { name + mimeType }
    var type: AttachType
    var dataUrl: String?
    var content: String?
    var name: String
    var mimeType: String
    var size: Int?
}

// MARK: - BranchRecord

struct BranchRecord: Codable {
    var content: String
    var tail: [ChatMessage]
}

// MARK: - ChatMessage

struct ChatMessage: Identifiable, Codable {
    enum MessageType: String, Codable {
        case user, assistant
        case toolEvent = "tool_event"
        case approval
        case systemStatus = "system_status"
    }

    enum MessageStatus: String, Codable {
        case streaming, completed, stopped, failed
    }

    let id: String
    let type: MessageType
    var createdAt: Date
    var content: String?
    var attachments: [ChatAttachment]?
    var branches: [BranchRecord]?
    var status: MessageStatus?
    var streaming: Bool?
    var tool: ToolEvent?
    var approval: ApprovalRequest?
    var statusText: String?
    // Invisible transport metadata: preserves the [VOICE_MODE] marker when this
    // message is replayed into model history without showing it in the UI.
    var voiceMode: Bool?
    // Web-search source cards, accumulated onto the assistant message from
    // web_search tool.completed events during the run.
    var sources: [WebSource]?
    // Files the agent sent via send_file, accumulated onto the assistant message
    // from tool.completed events; rendered as downloadable file cards.
    var files: [SentFile]?

    enum CodingKeys: String, CodingKey {
        case id, type, content, attachments, branches, status, streaming, tool, approval, createdAt, statusText, sources, files, voiceMode
    }

    init(id: String, type: MessageType, content: String? = nil,
         status: MessageStatus? = nil, streaming: Bool? = nil, voiceMode: Bool? = nil) {
        self.id = id; self.type = type; self.content = content
        self.status = status; self.streaming = streaming; self.voiceMode = voiceMode
        self.createdAt = Date()
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // id + type are required to make a usable message; everything else is
        // decoded defensively. The web app and iOS share the same SQLite store,
        // and the web writes fields iOS doesn't model strictly (e.g. a `status`
        // string like "error"/"pending"/"active" that isn't in MessageStatus, or
        // a `tool`/`approval` object with a different shape). `decodeIfPresent`
        // THROWS on a present-but-unknown value, so a single such message would
        // otherwise fail the whole `[ChatMessage]` decode and blank the chat.
        // Wrap each optional in `try?` so one odd field never loses the message.
        id = try c.decode(String.self, forKey: .id)
        type = try c.decode(MessageType.self, forKey: .type)
        content = (try? c.decodeIfPresent(String.self, forKey: .content)) ?? nil
        attachments = (try? c.decodeIfPresent([ChatAttachment].self, forKey: .attachments)) ?? nil
        branches = (try? c.decodeIfPresent([BranchRecord].self, forKey: .branches)) ?? nil
        status = (try? c.decodeIfPresent(MessageStatus.self, forKey: .status)) ?? nil
        streaming = (try? c.decodeIfPresent(Bool.self, forKey: .streaming)) ?? nil
        tool = (try? c.decodeIfPresent(ToolEvent.self, forKey: .tool)) ?? nil
        approval = (try? c.decodeIfPresent(ApprovalRequest.self, forKey: .approval)) ?? nil
        statusText = (try? c.decodeIfPresent(String.self, forKey: .statusText)) ?? nil
        sources = (try? c.decodeIfPresent([WebSource].self, forKey: .sources)) ?? nil
        files = (try? c.decodeIfPresent([SentFile].self, forKey: .files)) ?? nil
        voiceMode = (try? c.decodeIfPresent(Bool.self, forKey: .voiceMode)) ?? nil
        let s = (try? c.decodeIfPresent(String.self, forKey: .createdAt)) ?? nil
        createdAt = ISO8601DateFormatter.parse(s ?? "") ?? Date()
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(type, forKey: .type)
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        try c.encode(iso.string(from: createdAt), forKey: .createdAt)
        try c.encodeIfPresent(content, forKey: .content)
        try c.encodeIfPresent(attachments, forKey: .attachments)
        try c.encodeIfPresent(branches, forKey: .branches)
        try c.encodeIfPresent(status, forKey: .status)
        // Don't persist streaming flag
        try c.encodeIfPresent(tool, forKey: .tool)
        try c.encodeIfPresent(approval, forKey: .approval)
        try c.encodeIfPresent(statusText, forKey: .statusText)
        try c.encodeIfPresent(sources, forKey: .sources)
        try c.encodeIfPresent(files, forKey: .files)
        try c.encodeIfPresent(voiceMode, forKey: .voiceMode)
    }
}

// MARK: - ISO8601DateFormatter helpers

extension ISO8601DateFormatter {
    static let flexible: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    static func parse(_ string: String) -> Date? {
        guard !string.isEmpty else { return nil }
        let withFrac = ISO8601DateFormatter()
        withFrac.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = withFrac.date(from: string) { return d }
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        if let d = plain.date(from: string) { return d }
        // Try without timezone
        let noTZ = DateFormatter()
        noTZ.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        return noTZ.date(from: string)
    }
}
