import SwiftUI
import MarkdownUI

// MARK: - MessageView (dispatcher)

struct MessageView: View, Equatable {
    @Environment(SettingsStore.self) private var settings
    @Environment(ChatStore.self) private var chatStore
    let message: ChatMessage
    let chatId: String

    // Skip re-evaluating unchanged rows. Without this, every coalesced streaming
    // delta mutates chatStore.messages → ChatView.body re-runs → the ForEach
    // rebuilds and ALL visible rows re-evaluate, which is the layout storm that
    // wedged the main thread. Compare only the fields that affect how a row renders;
    // the streaming row's `content` changes so it still updates, while every other
    // row is skipped. (Used via `.equatable()` in ChatView.)
    static func == (l: MessageView, r: MessageView) -> Bool {
        l.chatId == r.chatId
            && l.message.id == r.message.id
            && l.message.type == r.message.type
            && l.message.content == r.message.content
            && l.message.streaming == r.message.streaming
            && l.message.status == r.message.status
            && l.message.statusText == r.message.statusText
            && (l.message.sources?.count ?? 0) == (r.message.sources?.count ?? 0)
            && (l.message.files?.count ?? 0) == (r.message.files?.count ?? 0)
            && l.message.tool?.completed == r.message.tool?.completed
            && l.message.tool?.error == r.message.tool?.error
            && l.message.tool?.resultSummary == r.message.tool?.resultSummary
            && l.message.approval?.status == r.message.approval?.status
            && (l.message.attachments?.count ?? 0) == (r.message.attachments?.count ?? 0)
            && (l.message.branches?.count ?? 0) == (r.message.branches?.count ?? 0)
    }

    var body: some View {
        switch message.type {
        case .user:       UserMessageView(message: message, chatId: chatId)
        case .assistant:  AssistantMessageView(message: message, chatId: chatId)
        case .toolEvent:  EmptyView()  // handled by ToolTimelineView at ChatView level
        case .approval:   ApprovalCardView(message: message, chatId: chatId)
        case .systemStatus: SystemStatusView(message: message)
        }
    }
}

// MARK: - UserMessageView (with edit + branch navigation)

struct UserMessageView: View {
    @Environment(ChatStore.self) private var chatStore
    let message: ChatMessage
    let chatId: String

    @State private var isEditing = false
    @State private var editText = ""

    private var branches: [BranchRecord] { message.branches ?? [] }
    private var hasBranches: Bool { !branches.isEmpty }

    var body: some View {
        VStack(alignment: .trailing, spacing: 4) {
            HStack(alignment: .top, spacing: 0) {
                Spacer(minLength: 60)
                VStack(alignment: .trailing, spacing: 6) {
                    // Attachments
                    if let atts = message.attachments {
                        ForEach(atts) { att in AttachmentPreview(attachment: att) }
                    }

                    // Message bubble
                    if isEditing {
                        editBubble
                    } else {
                        messageBubble
                    }
                }
            }
            .padding(.horizontal, 16)

            // Branch navigation (below the bubble, full-width right-aligned)
            if hasBranches && !isEditing {
                branchNavigation
                    .padding(.trailing, 16)
            }
        }
        .padding(.vertical, 6)
    }

    private var messageBubble: some View {
        Text(message.content ?? "")
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(Color.accentColor)
            .foregroundStyle(.white)
            .clipShape(RoundedRectangle(cornerRadius: 18))
            .textSelection(.enabled)
            .contextMenu {
                Button {
                    editText = message.content ?? ""
                    isEditing = true
                } label: { Label("Edit", systemImage: "pencil") }

                Button {
                    UIPasteboard.general.string = message.content
                } label: { Label("Copy", systemImage: "doc.on.doc") }
            }
    }

    private var editBubble: some View {
        VStack(alignment: .trailing, spacing: 6) {
            TextField("Edit message", text: $editText, axis: .vertical)
                .lineLimit(1...12)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(Color.accentColor.opacity(0.15))
                .clipShape(RoundedRectangle(cornerRadius: 18))
                .overlay(RoundedRectangle(cornerRadius: 18).stroke(Color.accentColor, lineWidth: 1.5))

            HStack(spacing: 8) {
                Button("Cancel") {
                    isEditing = false
                    editText = ""
                }
                .font(.caption)
                .foregroundStyle(.secondary)

                Button("Send") {
                    let trimmed = editText.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !trimmed.isEmpty else { return }
                    isEditing = false
                    chatStore.editMessage(chatId: chatId, msgId: message.id, newContent: trimmed)
                }
                .font(.caption).bold()
                .disabled(editText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
    }

    private var branchNavigation: some View {
        let (pos, total) = chatStore.branchState(msgId: message.id, branches: branches)
        return HStack(spacing: 4) {
            Button {
                Haptics.selection()
                chatStore.navigateBranch(chatId: chatId, msgId: message.id, delta: -1)
            } label: {
                Image(systemName: "chevron.left")
                    .font(.caption2)
            }
            .disabled(pos <= 1)
            .accessibilityLabel("chevron.left")

            Text("\(pos) / \(total)")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .monospacedDigit()

            Button {
                Haptics.selection()
                chatStore.navigateBranch(chatId: chatId, msgId: message.id, delta: 1)
            } label: {
                Image(systemName: "chevron.right")
                    .font(.caption2)
            }
            .disabled(pos >= total)
            .accessibilityLabel("chevron.right")
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
    }
}

// MARK: - AssistantMessageView

struct AssistantMessageView: View {
    @Environment(ChatStore.self) private var chatStore
    @Environment(SettingsStore.self) private var settings
    let message: ChatMessage
    let chatId: String

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            // Avatar
            Circle()
                .fill(Color(.systemGray5))
                .frame(width: 28, height: 28)
                .overlay {
                    Image(systemName: "sparkles")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                }

            VStack(alignment: .leading, spacing: 6) {
                if let content = message.content, !content.isEmpty {
                    if message.streaming == true {
                        // Live Markdown while streaming, but only the active (last) block
                        // re-parses per token — completed blocks are frozen — so long
                        // replies don't hang the main thread. See StreamingMarkdownView.
                        StreamingMarkdownView(content: content, baseURL: settings.client?.baseURL, apiKey: settings.apiKey)
                    } else {
                        // .equatable() so a completed message isn't re-evaluated /
                        // re-measured on every layout pass (e.g. while you're typing in
                        // the composer or another message streams) — only when its own
                        // text changes.
                        MarkdownContentView(content: content, baseURL: settings.client?.baseURL, apiKey: settings.apiKey)
                            .equatable()
                    }
                } else if message.streaming == true {
                    // Match the avatar height so the dots/"Generating…" sit level
                    // with the avatar instead of hanging below it (top-aligned row).
                    TypingIndicator()
                        .frame(height: 28, alignment: .leading)
                }

                // Cards render only once the answer has finished streaming —
                // sources arrive on the web_search tool.completed event, which
                // fires well before the response text, so showing them eagerly
                // would put the cards above an empty/streaming answer.
                if message.streaming != true, let sources = message.sources, !sources.isEmpty {
                    SourceCardsView(sources: sources, baseURL: settings.client?.baseURL)
                        .padding(.top, 2)
                }

                if message.streaming != true {
                    HStack(spacing: 12) {
                        CopyButton(text: message.content ?? "")
                    }
                    .padding(.top, 2)
                }
            }
            Spacer(minLength: 40)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
    }
}

// MARK: - ApprovalCardView

struct ApprovalCardView: View {
    @Environment(ChatStore.self) private var chatStore
    let message: ChatMessage
    let chatId: String

    private var approval: ApprovalRequest? { message.approval }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Spacer().frame(width: 38)
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    riskBadge
                    Text(approval?.title ?? "Approval Required")
                        .font(.subheadline).bold()
                }
                if let reason = approval?.reason {
                    Text(reason).font(.caption).foregroundStyle(.secondary)
                }
                if let cmd = approval?.commandPreview {
                    Text(cmd)
                        .font(.system(.caption, design: .monospaced))
                        .padding(8)
                        .background(Color(.systemGray6))
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                }
                if approval?.status == .pending {
                    HStack(spacing: 8) {
                        approvalButton("Once",    choice: "once",    color: .blue)
                        approvalButton("Session", choice: "session", color: .indigo)
                        approvalButton("Always",  choice: "always",  color: .green)
                        approvalButton("Deny",    choice: "deny",    color: .red)
                    }
                } else {
                    Text("Status: \(approval?.status.rawValue ?? "unknown")")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .padding(12)
            .background(Color(.systemGray6))
            .clipShape(RoundedRectangle(cornerRadius: 12))
            Spacer(minLength: 16)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 4)
    }

    private func approvalButton(_ label: String, choice: String, color: Color) -> some View {
        Button(label) {
            Task {
                await chatStore.approveRun(chatId: chatId, approvalId: approval?.id ?? "", choice: choice)
            }
        }
        .font(.caption)
        .padding(.horizontal, 10).padding(.vertical, 5)
        .background(color.opacity(0.15))
        .foregroundStyle(color)
        .clipShape(Capsule())
    }

    private var riskBadge: some View {
        let (label, color): (String, Color) = {
            switch approval?.riskLevel {
            case .low:    return ("Low", .green)
            case .medium: return ("Medium", .orange)
            case .high:   return ("High", .red)
            default:      return ("", .clear)
            }
        }()
        return Group {
            if !label.isEmpty {
                Text(label)
                    .font(.caption2).bold()
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(color.opacity(0.15))
                    .foregroundStyle(color)
                    .clipShape(Capsule())
            }
        }
    }
}

// MARK: - SystemStatusView

struct SystemStatusView: View {
    let message: ChatMessage

    var body: some View {
        HStack {
            Spacer()
            Text(message.content ?? message.statusText ?? "")
                .font(.caption).foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 16).padding(.vertical, 4)
            Spacer()
        }
    }
}

// MARK: - AttachmentPreview

struct AttachmentPreview: View {
    let attachment: ChatAttachment
    @State private var showLightbox = false

    var body: some View {
        if attachment.type == .image,
           let dataUrl = attachment.dataUrl,
           let b64 = dataUrl.components(separatedBy: ",").last,
           let data = Data(base64Encoded: b64),
           let img = UIImage(data: data) {
            Image(uiImage: img)
                .resizable().scaledToFit()
                .frame(maxWidth: 200)
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .onTapGesture {
                    Haptics.impact(.light)
                    showLightbox = true
                }
                .fullScreenCover(isPresented: $showLightbox) {
                    ImageLightboxView(image: img) { showLightbox = false }
                }
        } else {
            Label(attachment.name, systemImage: "doc")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}

// MARK: - TypingIndicator

struct TypingIndicator: View {
    @State private var phase = 0
    @State private var elapsed = 0
    // After a couple seconds with no token, surface elapsed time so a long cold
    // prefill (the gateway's ~12k-token context can take ~20s cold) reads as
    // "working" rather than a hang.
    private let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        HStack(spacing: 6) {
            HStack(spacing: 4) {
                ForEach(0..<3) { i in
                    Circle()
                        .fill(Color.secondary.opacity(phase == i ? 1 : 0.3))
                        .frame(width: 7, height: 7)
                        .animation(.easeInOut(duration: 0.4).delay(Double(i) * 0.15).repeatForever(), value: phase)
                }
            }
            if elapsed >= 2 {
                Text("Generating… \(elapsed)s")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .transition(.opacity)
            }
        }
        .onAppear { phase = 1 }
        .onReceive(timer) { _ in withAnimation { elapsed += 1 } }
    }
}

// MARK: - Source cards (web_search results)

/// Link-preview metadata fetched from the interface server `/api/link-preview`.
struct LinkPreviewData: Decodable {
    var title: String?
    var image: String?
    var siteName: String?
    var date: String?
    var description: String?
    var url: String?
    var favicon: String?
}

/// In-memory, deduped loader for link previews. Shared across cards so the same
/// URL is fetched at most once per app session (the server also caches 24h).
actor LinkPreviewStore {
    static let shared = LinkPreviewStore()
    private var cache: [String: LinkPreviewData] = [:]
    private var inflight: [String: Task<LinkPreviewData?, Never>] = [:]

    func load(url: String, baseURL: URL) async -> LinkPreviewData? {
        if let hit = cache[url] { return hit }
        if let task = inflight[url] { return await task.value }
        let task = Task<LinkPreviewData?, Never> {
            var comps = URLComponents(url: baseURL.appendingPathComponent("/api/link-preview"),
                                      resolvingAgainstBaseURL: false)
            comps?.queryItems = [URLQueryItem(name: "url", value: url)]
            guard let reqURL = comps?.url else { return nil }
            do {
                let (data, resp) = try await URLSession.shared.data(from: reqURL)
                guard (resp as? HTTPURLResponse)?.statusCode == 200 else { return nil }
                return try? JSONDecoder().decode(LinkPreviewData.self, from: data)
            } catch {
                return nil
            }
        }
        inflight[url] = task
        let result = await task.value
        inflight[url] = nil
        if let result { cache[url] = result }
        return result
    }
}

/// Horizontal row of source cards rendered under a web-search answer.
struct SourceCardsView: View {
    let sources: [WebSource]
    let baseURL: URL?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("Sources", systemImage: "globe")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(sources) { source in
                        SourceCardView(source: source, baseURL: baseURL)
                    }
                }
                .padding(.horizontal, 1)
            }
        }
    }
}

private struct SourceCardView: View {
    let source: WebSource
    let baseURL: URL?
    @Environment(\.openURL) private var openURL
    @State private var preview: LinkPreviewData?

    private var host: String {
        guard let h = URL(string: source.url)?.host else { return "" }
        return h.hasPrefix("www.") ? String(h.dropFirst(4)) : h
    }

    private var publisher: String {
        let s = preview?.siteName?.trimmingCharacters(in: .whitespaces) ?? ""
        return s.isEmpty ? host : s
    }

    private var displayDate: String? {
        guard let raw = preview?.date, !raw.isEmpty,
              let d = ISO8601DateFormatter.parse(raw) else { return nil }
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .none
        return f.string(from: d)
    }

    private var imageURL: URL? {
        guard let s = preview?.image, !s.isEmpty else { return nil }
        return URL(string: s)
    }

    private var faviconURL: URL? {
        if let s = preview?.favicon, !s.isEmpty, let u = URL(string: s) { return u }
        // Last resort (covers a failed/502 preview too): the host's /favicon.ico.
        if let comps = URLComponents(string: source.url), let host = comps.host {
            return URL(string: "\(comps.scheme ?? "https")://\(host)/favicon.ico")
        }
        return nil
    }

    private var title: String {
        let t = source.title.trimmingCharacters(in: .whitespacesAndNewlines)
        if !t.isEmpty { return t }
        let pt = preview?.title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return pt.isEmpty ? host : pt
    }

    // Consistent 200×96 header: hero og:image when present, else the site
    // favicon centered on a tint, else a globe — so cards line up even when a
    // page has no preview image (which is common).
    @ViewBuilder private var header: some View {
        ZStack {
            Color(.systemGray6)
            if let imageURL {
                AsyncImage(url: imageURL) { phase in
                    switch phase {
                    case .success(let img): img.resizable().scaledToFill()
                    case .empty: ProgressView()
                    default: faviconOrGlobe
                    }
                }
            } else {
                faviconOrGlobe
            }
        }
        .frame(width: 200, height: 96)
        .clipped()
    }

    @ViewBuilder private var faviconOrGlobe: some View {
        if let faviconURL {
            AsyncImage(url: faviconURL) { phase in
                if case .success(let img) = phase {
                    img.resizable().scaledToFit().frame(width: 36, height: 36)
                } else {
                    Image(systemName: "globe").font(.title2).foregroundStyle(.secondary)
                }
            }
        } else {
            Image(systemName: "globe").font(.title2).foregroundStyle(.secondary)
        }
    }

    var body: some View {
        Button {
            if let u = URL(string: source.url) {
                Haptics.impact(.light)
                openURL(u)
            }
        } label: {
            VStack(alignment: .leading, spacing: 0) {
                header
                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                    HStack(spacing: 4) {
                        Text(publisher).lineLimit(1)
                        if let displayDate {
                            Text("·")
                            Text(displayDate).lineLimit(1)
                        }
                    }
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                }
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(width: 200, alignment: .leading)
            .background(Color(.systemGray6))
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.primary.opacity(0.08)))
        }
        .buttonStyle(.plain)
        .task(id: source.url) {
            guard let baseURL else { return }
            preview = await LinkPreviewStore.shared.load(url: source.url, baseURL: baseURL)
        }
    }
}
