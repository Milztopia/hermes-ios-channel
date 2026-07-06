import Foundation
import Observation
import UserNotifications
import UIKit

// MARK: - ChatStore

@Observable
@MainActor
final class ChatStore {
    var chats: [UiChat] = []
    var trashedChats: [UiChat] = []
    var projects: [Project] = []
    var activeChatId: String? {
        didSet {
            // Leaving a brand-new chat without sending anything? Drop it so an
            // empty "New Chat" never lingers in the sidebar (it was never saved
            // server-side — see newChat / draftChatIds).
            if let old = oldValue, old != activeChatId {
                discardDraftIfEmpty(chatId: old)
            }
        }
    }
    var messages: [String: [ChatMessage]] = [:]

    // Chats created locally but not yet persisted server-side. A new chat stays
    // a draft until its first message is sent (then startRun creates it). Drafts
    // abandoned with no messages are discarded instead of saved.
    private var draftChatIds: Set<String> = []

    var runningRunId: [String: String] = [:]
    var isStreaming: [String: Bool] = [:]
    private var runsWithOutput: Set<String> = []
    @ObservationIgnored private var deferredMessageDeltas: [String: String] = [:]

    private static let voiceNoResponseDeadline: Duration = .seconds(90)
    private static let voiceTimeoutReply = "I may have misheard an important name or phrase. Could you repeat it or spell it for me?"

    // Branch position tracking: msgId -> index into branches array (branches.count = live)
    var branchPosition: [String: Int] = [:]

    // Per-chat toolset override: chatId -> [toolset keys]. When a chat has an
    // entry, its runs send enabled_toolsets to override the universal config.
    var chatToolsetOverride: [String: [String]] = [:] {
        didSet {
            UserDefaults.standard.set(chatToolsetOverride, forKey: "hermes.chatToolsetOverride")
        }
    }
    // Every new chat snapshots the global Voice setting. Changes made from the
    // voice overlay update only that chat's value.
    private var chatBargeInPreference: [String: Bool] = [:] {
        didSet {
            UserDefaults.standard.set(chatBargeInPreference, forKey: "hermes.chatBargeInPreference")
        }
    }

    private weak var settings: SettingsStore?
    private let chatCacheKey = "hermes.chatListCache"

    init() {
        if let stored = UserDefaults.standard.dictionary(forKey: "hermes.chatToolsetOverride") as? [String: [String]] {
            chatToolsetOverride = stored
        }
        if let stored = UserDefaults.standard.dictionary(forKey: "hermes.chatBargeInPreference") as? [String: Bool] {
            chatBargeInPreference = stored
        }
        loadCachedChats()
    }

    func attach(settings: SettingsStore) { self.settings = settings }

    // MARK: - Load

    private var didLoadAll = false

    func loadAll() async {
        guard let client = settings?.client else { return }
        // Both the app-launch task and SidebarView.task call this. Dedupe so two
        // concurrent loads don't race: the flag is set synchronously before the
        // first await, so a second caller bails before overwriting `chats` (which
        // would orphan the launch draft and break the default chat).
        if didLoadAll { return }
        didLoadAll = true

        let hadCachedChats = chats.contains { !draftChatIds.contains($0.id) }

        // Make launch usable immediately. Cached history and remote
        // history/projects can arrive without blocking the first empty chat.
        if activeChatId == nil {
            _ = await newChat()
        }

        async let ct = client.listChats(updatedWithinDays: hadCachedChats ? 7 : nil)
        async let pt = client.listProjects()
        if let c = try? await ct {
            let remoteIds = Set(c.map(\.id))
            let localDrafts = chats.filter { draftChatIds.contains($0.id) && !remoteIds.contains($0.id) }
            let cachedRest = chats.filter { !draftChatIds.contains($0.id) && !remoteIds.contains($0.id) }
            chats = localDrafts + c + cachedRest
            persistChatCache()
        }
        if let p = try? await pt { projects = p }

        // Do not create/select a chat after remote loading completes. If the
        // user backed out to the chat list while history was loading, a late
        // auto-selection would push them back into a new chat.
    }

    // Per-chat in-flight load tasks, so loads are deduped and — crucially — OWNED
    // BY THE STORE rather than the view. A SwiftUI `.task` is cancelled when its
    // view is torn down during navigation/re-layout, which was cancelling the
    // history fetch mid-flight (NSURLErrorCancelled -999) and leaving old chats
    // blank. A store-owned Task survives that and completes the load.
    private var messageLoadTasks: [String: Task<Void, Never>] = [:]
    private var loadingMessageChatIds: Set<String> = []

    /// Ensure a chat's history is loaded. Safe to call repeatedly (deduped); the
    /// fetch runs independent of any view lifecycle so it can't be cancelled by
    /// navigating away and back.
    func loadMessagesIfNeeded(chatId: String) {
        guard messages[chatId] == nil,
              messageLoadTasks[chatId] == nil,
              let client = settings?.client else { return }
        loadingMessageChatIds.insert(chatId)
        let task = Task { [weak self] in
            do {
                let msgs = try await client.getMessages(chatId)
                self?.messages[chatId] = msgs.filter { $0.streaming != true }
                self?.refreshChatMetadataFromMessages(chatId: chatId, messages: msgs)
            } catch {
                NSLog("HERMES loadMessages ERROR chatId=\(chatId): \(error)")
            }
            self?.messageLoadTasks[chatId] = nil
            self?.loadingMessageChatIds.remove(chatId)
        }
        messageLoadTasks[chatId] = task
    }

    func isLoadingMessages(chatId: String) -> Bool {
        loadingMessageChatIds.contains(chatId)
    }

    /// Async variant retained for callers that want to await the load.
    func loadMessages(chatId: String) async {
        loadMessagesIfNeeded(chatId: chatId)
        if let task = messageLoadTasks[chatId] { await task.value }
    }

    // MARK: - Chat management

    func newChat(temporary: Bool = false) async -> UiChat? {
        let id = UUID().uuidString
        let chat = UiChat(id: id, title: "New Chat", pinned: false, archived: false,
                          createdAt: Date(), updatedAt: Date(), lastMessagePreview: "",
                          projectId: nil, hermesSessionId: nil, modelProvider: nil,
                          modelId: nil, isTemporary: temporary)
        // Don't touch the server yet — a new chat is local-only until its first
        // message (startRun promotes it). This keeps abandoned empties off the
        // server entirely. Temporary chats are never persisted regardless.
        if !temporary { draftChatIds.insert(id) }
        chatBargeInPreference[id] = settings?.defaultBargeInEnabled ?? false
        chats.insert(chat, at: 0)
        messages[chat.id] = []
        activeChatId = chat.id
        return chat
    }

    /// True for a brand-new chat that hasn't sent its first message yet.
    func isDraft(_ chatId: String) -> Bool { draftChatIds.contains(chatId) }

    /// Remove a draft chat that's being left with nothing in it. No server call
    /// is needed because a draft was never persisted.
    private func discardDraftIfEmpty(chatId: String) {
        guard draftChatIds.contains(chatId) else { return }
        guard (messages[chatId]?.isEmpty ?? true), isStreaming[chatId] != true else { return }
        draftChatIds.remove(chatId)
        chats.removeAll { $0.id == chatId }
        messages.removeValue(forKey: chatId)
        chatToolsetOverride.removeValue(forKey: chatId)
        chatBargeInPreference.removeValue(forKey: chatId)
    }

    /// Create a draft chat server-side before its first message persists.
    /// Returns false (after surfacing an error) if creation failed.
    private func promoteDraftIfNeeded(chatId: String, client: HermesClient) async -> Bool {
        guard draftChatIds.contains(chatId),
              let idx = chats.firstIndex(where: { $0.id == chatId }) else { return true }
        do {
            _ = try await client.createChat(id: chatId, title: chats[idx].title)
            draftChatIds.remove(chatId)
            return true
        } catch {
            addMessage(chatId: chatId, message: ChatMessage(
                id: "err-\(UUID().uuidString)", type: .systemStatus,
                content: "Couldn't create chat: \(error.localizedDescription)"))
            return false
        }
    }

    func renameChat(_ chatId: String, title: String) async {
        update(chatId: chatId) { $0.title = title }
        try? await settings?.client?.updateChat(chatId, changes: ["title": title])
    }

    /// Persist the Hermes session id for a chat (local + backend), so future
    /// runs send it as session_id and the conversation stays a single session.
    func setHermesSessionId(_ chatId: String, sessionId: String) async {
        update(chatId: chatId) { $0.hermesSessionId = sessionId }
        try? await settings?.client?.updateChat(chatId, changes: ["hermes_session_id": sessionId])
    }

    func deleteChat(_ chatId: String) async {
        let deleted = chats.first { $0.id == chatId }
        let wasDraft = draftChatIds.remove(chatId) != nil
        chats.removeAll { $0.id == chatId }
        messages.removeValue(forKey: chatId)
        chatBargeInPreference.removeValue(forKey: chatId)
        persistChatCache()
        if activeChatId == chatId { activeChatId = nil }
        if !wasDraft, let deleted {
            trashedChats.removeAll { $0.id == chatId }
            trashedChats.insert(deleted, at: 0)
        }
        guard !wasDraft else { return }
        if let client = settings?.client {
            try? await client.deleteChat(chatId)
            await loadTrash()
        }
    }

    func loadTrash() async {
        guard let client = settings?.client else { return }
        if let trash = try? await client.listTrash() {
            trashedChats = trash
        }
    }

    func restoreChat(_ chatId: String) async {
        guard let client = settings?.client else { return }
        guard let restored = try? await client.restoreChat(chatId) else { return }
        trashedChats.removeAll { $0.id == chatId }
        chats.removeAll { $0.id == restored.id }
        chats.append(restored)
        sortChats()
        persistChatCache()
    }

    func emptyTrash() async {
        guard let client = settings?.client else { return }
        do {
            try await client.emptyTrash()
            trashedChats.removeAll()
        } catch {
            NSLog("HERMES emptyTrash ERROR: \(error)")
        }
    }

    func bargeInEnabled(for chatId: String, default defaultValue: Bool) -> Bool {
        chatBargeInPreference[chatId] ?? defaultValue
    }

    func setBargeInEnabled(_ enabled: Bool, for chatId: String) {
        chatBargeInPreference[chatId] = enabled
    }

    func pinChat(_ chatId: String, pinned: Bool) async {
        update(chatId: chatId) { $0.pinned = pinned }
        try? await settings?.client?.updateChat(chatId, changes: ["pinned": pinned])
    }

    func archiveChat(_ chatId: String) async {
        update(chatId: chatId) { $0.archived = true }
        if activeChatId == chatId { activeChatId = nil }
        try? await settings?.client?.updateChat(chatId, changes: ["archived": true])
    }

    func moveChatToProject(_ chatId: String, projectId: String?) async {
        update(chatId: chatId) { $0.projectId = projectId }
        try? await settings?.client?.updateChat(chatId, changes: ["project_id": projectId as Any])
    }

    func setChatModelOverride(_ chatId: String, provider: String?, modelId: String?) async {
        let cleanProvider = provider?.isEmpty == false ? provider : nil
        let cleanModel = modelId?.isEmpty == false ? modelId : nil
        update(chatId: chatId) {
            $0.modelProvider = cleanProvider
            $0.modelId = cleanModel
        }
        try? await settings?.client?.updateChat(chatId, changes: [
            "model_provider": cleanProvider ?? NSNull(),
            "model_id": cleanModel ?? NSNull()
        ])
    }

    private func effectiveModel(for chat: UiChat, settings: SettingsStore?) -> (provider: String?, model: String?) {
        if let provider = chat.modelProvider, !provider.isEmpty,
           let model = chat.modelId, !model.isEmpty {
            return (provider, model)
        }
        guard let settings, !settings.selectedProvider.isEmpty, !settings.selectedModel.isEmpty else {
            return (nil, nil)
        }
        return (settings.selectedProvider, settings.selectedModel)
    }

    // MARK: - Project management

    func createProject(name: String, color: String) async {
        guard let client = settings?.client,
              let p = try? await client.createProject(name: name, color: color) else { return }
        projects.append(p)
    }

    func deleteProject(_ projectId: String) async {
        // Move its chats to uncategorized
        for i in chats.indices where chats[i].projectId == projectId {
            chats[i].projectId = nil
        }
        projects.removeAll { $0.id == projectId }
        try? await settings?.client?.deleteProject(projectId)
    }

    func renameProject(_ projectId: String, name: String) async {
        guard let idx = projects.firstIndex(where: { $0.id == projectId }) else { return }
        projects[idx].name = name
        // No server endpoint for patch in current client; extend if needed
    }

    // MARK: - Message branching

    // Returns (currentPosition 1-indexed, total) for display: e.g. "2 / 3"
    func branchState(msgId: String, branches: [BranchRecord]) -> (Int, Int) {
        let total = branches.count + 1
        let pos = branchPosition[msgId] ?? total
        return (pos, total)
    }

    func navigateBranch(chatId: String, msgId: String, delta: Int) {
        guard let msgIdx = messages[chatId]?.firstIndex(where: { $0.id == msgId }),
              var msg = messages[chatId]?[msgIdx] else { return }

        var branches = msg.branches ?? []
        guard !branches.isEmpty else { return }

        let total = branches.count + 1
        let currentPos = branchPosition[msgId] ?? total
        let newPos = max(1, min(total, currentPos + delta))
        guard newPos != currentPos else { return }

        // Save current display state
        let liveContent = msg.content ?? ""
        var arr = messages[chatId]!
        let liveTail = msgIdx + 1 < arr.count ? Array(arr[(msgIdx + 1)...]) : []

        if currentPos <= branches.count {
            branches[currentPos - 1] = BranchRecord(content: liveContent, tail: liveTail)
        } else {
            // Navigating away from live — append live as the last saved branch
            branches.append(BranchRecord(content: liveContent, tail: liveTail))
            // newPos is now still valid because it was <= branches.count before append
        }

        // Load target. If newPos <= branches.count, load that branch.
        // If newPos == new total, that means live (which we just appended to branches),
        // so we always have something at newPos-1.
        let safeIdx = min(newPos - 1, branches.count - 1)
        let target = branches[safeIdx]

        msg.content = target.content
        msg.branches = branches
        arr[msgIdx] = msg
        let prefix = Array(arr[...msgIdx])
        messages[chatId] = prefix + target.tail
        branchPosition[msgId] = newPos
    }

    func editMessage(chatId: String, msgId: String, newContent: String) {
        guard let msgIdx = messages[chatId]?.firstIndex(where: { $0.id == msgId }),
              var msg = messages[chatId]?[msgIdx] else { return }

        var arr = messages[chatId]!
        let currentContent = msg.content ?? ""
        let currentTail = msgIdx + 1 < arr.count ? Array(arr[(msgIdx + 1)...]) : []

        // Save current state as a branch
        var branches = msg.branches ?? []
        if branches.isEmpty {
            branches = [BranchRecord(content: currentContent, tail: currentTail)]
        } else {
            let pos = branchPosition[msgId] ?? (branches.count + 1)
            if pos <= branches.count {
                branches[pos - 1].tail = currentTail
            } else {
                branches.append(BranchRecord(content: currentContent, tail: currentTail))
            }
        }

        msg.content = newContent
        msg.branches = branches
        arr[msgIdx] = msg
        messages[chatId] = Array(arr[...msgIdx])  // strip tail
        branchPosition[msgId] = branches.count + 1  // pointing to new live

        Task { await startRun(chatId: chatId, text: newContent) }
    }

    // MARK: - Run lifecycle

    /// Stable system-prompt policy for both text and voice turns. Voice mode is
    /// signaled in the current user message so switching modes changes only the
    /// uncached tail instead of invalidating the entire system-prompt prefix.
    static let modalityInstructions = """
    A user message may begin with metadata markers. Never mention or repeat them.
    When the user corrects your approach or says to do something differently, treat \
    that as the instruction for this turn and carry it out immediately. Do not only \
    apologize, acknowledge, promise to do it, or say you will do it now; either do \
    the requested work in the same response or ask the specific blocking question.
    When [WEB_SEARCH_REQUIRED] is present, you MUST call web_search before answering. \
    Do not answer from memory, estimates, or prior knowledge, even if you believe you \
    already know the answer. Base the answer on the returned current sources.
    When [VOICE_MODE] is present, the reply will be spoken aloud by text-to-speech, \
    so write for the ear rather than the eye:
    - Spell out numbers, dates, times, currency, and symbols in natural spoken words.
    - Do not use tables, charts, code blocks, lists, headings, emoji, or markdown.
    - Use concise, conversational, plain flowing sentences.
    - Speech recognition may mishear proper nouns. If a key term is uncertain and \
    an initial search finds nothing useful, try at most one plausible alternate \
    spelling. If it is still uncertain, ask the user to repeat or spell the term \
    instead of continuing unrelated searches or extracting unrelated pages.
    When the marker is absent, respond normally.
    """

    func startRun(chatId: String, text: String, images: [ChatAttachment] = [], voiceMode: Bool = false) async {
        guard let client = settings?.client,
              chats.contains(where: { $0.id == chatId }) else { return }

        let wasDraft = draftChatIds.contains(chatId)
        let userMsg = ChatMessage(
            id: "u-\(UUID().uuidString)", type: .user, content: text,
            voiceMode: voiceMode ? true : nil
        )
        if wasDraft {
            update(chatId: chatId) {
                $0.createdAt = userMsg.createdAt
                $0.updatedAt = userMsg.createdAt
            }
        }
        addMessage(chatId: chatId, message: userMsg)

        // First message in a brand-new chat: show the user's message immediately,
        // then create the server-side chat before starting the run. If creation
        // fails, the visible transcript now contains the exact error instead of
        // making Send look like a no-op.
        guard await promoteDraftIfNeeded(chatId: chatId, client: client) else { return }
        // promoteDraftIfNeeded awaits network I/O, so another MainActor task may
        // have changed the array. Never carry an Array index across that await.
        guard let chatIdx = chats.firstIndex(where: { $0.id == chatId }) else { return }

        // Title a brand-new chat from its first message (local-first, then sync).
        // The server stores the default as "New chat"; match case-insensitively.
        let currentTitle = chats[chatIdx].title
        if currentTitle.isEmpty || currentTitle.lowercased() == "new chat" {
            let cleanText = UiChat.withoutInternalMarkers(text)
            let firstLine = cleanText.trimmingCharacters(in: .whitespacesAndNewlines)
                .split(separator: "\n", omittingEmptySubsequences: true).first.map(String.init) ?? ""
            let derived = String(firstLine.prefix(48)).trimmingCharacters(in: .whitespaces)
            if !derived.isEmpty { Task { await renameChat(chatId, title: derived) } }
        }

        let history = buildHistory(chatId: chatId, excludeId: userMsg.id)

        let s = settings
        // Keep this identical across text and voice turns to preserve the
        // llama.cpp prompt-cache prefix. Only the current input carries the
        // short voice marker; the displayed/stored user message remains clean.
        var instructions = s?.systemPrompt.isEmpty == false ? (s?.systemPrompt ?? "") : ""
        instructions = instructions.isEmpty
            ? Self.modalityInstructions
            : instructions + "\n\n" + Self.modalityInstructions
        let requiresWebSearch = Self.requiresWebSearch(text)
        var requestMarkers: [String] = []
        if voiceMode { requestMarkers.append("[VOICE_MODE]") }
        if requiresWebSearch { requestMarkers.append("[WEB_SEARCH_REQUIRED]") }
        let requestText = requestMarkers.isEmpty
            ? text
            : requestMarkers.joined(separator: "\n") + "\n" + text
        let input: RunInput = images.isEmpty ? .text(requestText)
            : .parts(buildMultimodalParts(text: requestText, images: images))
        var runToolsets = chatToolsetOverride[chatId] ?? s?.effectiveTools
        // An explicit/current-information request must not be defeated by a chat
        // tool override that omitted web. nil already means "use server defaults,"
        // whose API-server configuration includes web.
        if requiresWebSearch, runToolsets != nil,
           runToolsets?.contains("web") != true {
            runToolsets?.append("web")
        }
        let selectedBrain = effectiveModel(for: chats[chatIdx], settings: s)
        let req = StartRunRequest(
            input: input, stream: true,
            model: selectedBrain.model,
            provider: selectedBrain.provider,
            instructions: instructions.isEmpty ? nil : instructions,
            conversationHistory: history,
            tools: runToolsets,
            // Honor the user's Tools-screen selection as the active toolsets: a
            // per-chat override wins, else the globally-enabled toolsets. This is
            // the lever that controls schema injection (~the prompt size), so
            // disabling heavy toolsets in the Tools screen directly shrinks the
            // context and cold-prefill cost. nil (tools not yet loaded) → gateway
            // uses its universal config.
            enabledToolsets: runToolsets
        )

        let sessionKey = "web:\(chatId)"
        let sessionId = chats[chatIdx].hermesSessionId

        do {
            TimingReporter.reset()
            let t0Run = Date()
            let resp = try await client.startRun(req, sessionKey: sessionKey, sessionId: sessionId)
            let rtt = Date().timeIntervalSince(t0Run)
            NSLog("HERMES⏱ startRun-rtt  +%.3fs  runId=%@", rtt, resp.runId)
            TimingReporter.mark("startRun-rtt", detail: "runId=\(resp.runId.prefix(8))")
            runningRunId[chatId] = resp.runId
            isStreaming[chatId] = true

            // First turn of a chat: the gateway used resp.runId as the new
            // session id (no session_id was sent). Persist it so every
            // subsequent turn continues the same Hermes session instead of
            // spawning a fresh one — keeping the chat threaded in state.db and
            // in the official desktop app.
            if sessionId == nil {
                await setHermesSessionId(chatId, sessionId: resp.runId)
            }

            var assistantMsg = ChatMessage(id: "a-\(UUID().uuidString)", type: .assistant, streaming: true)
            assistantMsg.content = ""
            addMessage(chatId: chatId, message: assistantMsg)

            let voiceWatchdog = voiceMode
                ? startVoiceNoResponseWatchdog(
                    chatId: chatId,
                    runId: resp.runId,
                    assistantMsgId: assistantMsg.id,
                    client: client
                )
                : nil
            await streamRun(chatId: chatId, runId: resp.runId,
                            assistantMsgId: assistantMsg.id, client: client)
            voiceWatchdog?.cancel()
        } catch {
            addMessage(chatId: chatId, message: ChatMessage(
                id: "err-\(UUID().uuidString)", type: .systemStatus, content: error.localizedDescription))
            isStreaming[chatId] = false
        }
    }

    func stopRun(chatId: String) async {
        guard let runId = runningRunId[chatId], let client = settings?.client else { return }
        try? await client.stopRun(runId)
    }

    private func startVoiceNoResponseWatchdog(
        chatId: String,
        runId: String,
        assistantMsgId: String,
        client: HermesClient
    ) -> Task<Void, Never> {
        Task { [weak self] in
            try? await Task.sleep(for: Self.voiceNoResponseDeadline)
            guard !Task.isCancelled, let self,
                  self.runningRunId[chatId] == runId,
                  self.isStreaming[chatId] == true,
                  !self.runsWithOutput.contains(runId) else { return }

            try? await client.stopRun(runId)
            guard var arr = self.messages[chatId],
                  let index = arr.lastIndex(where: { $0.id == assistantMsgId }) else {
                self.finalizeRun(chatId: chatId)
                return
            }
            arr[index].content = Self.voiceTimeoutReply
            arr[index].streaming = false
            arr[index].status = .completed
            self.messages[chatId] = arr
            self.finalizeRun(chatId: chatId)
        }
    }

    func approveRun(chatId: String, approvalId: String, choice: String) async {
        guard let runId = runningRunId[chatId], let client = settings?.client else { return }
        try? await client.approveRun(runId, approvalId: approvalId, choice: choice)
        updateApprovalStatus(chatId: chatId, approvalId: approvalId, status: choice)
    }

    // MARK: - Message helpers

    func addMessage(chatId: String, message: ChatMessage) {
        if messages[chatId] == nil { messages[chatId] = [] }
        messages[chatId]?.append(message)
        if (message.type == .user || message.type == .assistant),
           let content = message.content, !content.isEmpty,
           let idx = chats.firstIndex(where: { $0.id == chatId }) {
            chats[idx].lastMessagePreview = String(UiChat.withoutInternalMarkers(content).prefix(100))
            chats[idx].updatedAt = Date()
            persistChatCache()
        }
    }

    func appendDelta(chatId: String, msgId: String, delta: String) {
        guard let idx = messages[chatId]?.lastIndex(where: { $0.id == msgId }) else { return }
        var arr = messages[chatId]!
        arr[idx].content = (arr[idx].content ?? "") + delta
        messages[chatId] = arr
    }

    /// Full assistant content, including text intentionally withheld from the
    /// observable SwiftUI model while the app is backgrounded.
    func responseContent(chatId: String, msgId: String) -> String {
        let visible = messages[chatId]?.first(where: { $0.id == msgId })?.content ?? ""
        return visible + (deferredMessageDeltas[msgId] ?? "")
    }

    /// Publish background-buffered response text once the app is active again.
    /// This produces one layout pass per message instead of token-by-token layout
    /// work while iOS is trying to suspend the scene.
    func flushDeferredUIUpdates() {
        guard UIApplication.shared.applicationState == .active,
              !deferredMessageDeltas.isEmpty else { return }
        let pending = deferredMessageDeltas
        deferredMessageDeltas.removeAll()
        for chatId in Array(messages.keys) {
            guard var arr = messages[chatId] else { continue }
            var changed = false
            for index in arr.indices {
                guard let delta = pending[arr[index].id], !delta.isEmpty else { continue }
                arr[index].content = (arr[index].content ?? "") + delta
                changed = true
            }
            if changed { messages[chatId] = arr }
        }
    }

    func finalizeMessage(chatId: String, msgId: String) {
        guard let idx = messages[chatId]?.lastIndex(where: { $0.id == msgId }) else { return }
        var arr = messages[chatId]!
        arr[idx].streaming = false
        arr[idx].status = .completed
        messages[chatId] = arr
    }

    private func updateApprovalStatus(chatId: String, approvalId: String, status: String) {
        guard var arr = messages[chatId] else { return }
        for i in arr.indices where arr[i].approval?.id == approvalId {
            arr[i].approval?.status = ApprovalRequest.Status(rawValue: status) ?? .approved
        }
        messages[chatId] = arr
    }

    private func completeTool(chatId: String, toolName: String, toolCallId: String,
                              duration: Double?, summary: String?, isError: Bool) {
        guard var arr = messages[chatId] else { return }
        func pending(_ m: ChatMessage) -> Bool { m.type == .toolEvent && m.tool != nil && m.tool?.completed != true }
        // The real server omits tool_call_id, so match by id when present, else
        // the most recent still-running tool with the same name, else the most
        // recent still-running tool of any name.
        var target: Int? = nil
        if !toolCallId.isEmpty {
            target = arr.lastIndex { $0.tool?.toolCallId == toolCallId }
        }
        if target == nil, !toolName.isEmpty {
            target = arr.lastIndex { pending($0) && $0.tool?.tool == toolName }
        }
        if target == nil {
            target = arr.lastIndex { pending($0) }
        }
        guard let i = target else { return }
        arr[i].tool?.completed = true
        if let duration { arr[i].tool?.duration = duration }
        if let summary { arr[i].tool?.resultSummary = summary }
        if isError, arr[i].tool?.error == nil { arr[i].tool?.error = "Failed" }
        messages[chatId] = arr
    }

    /// Merge web-search sources onto the streaming assistant message so cards
    /// render under the answer (ChatGPT-style). Multiple searches in one run
    /// accumulate; dedupe by URL, preserving first-seen order.
    private func attachSources(chatId: String, msgId: String, sources: [WebSource]) {
        guard var arr = messages[chatId],
              let i = arr.lastIndex(where: { $0.id == msgId }) else { return }
        var merged = arr[i].sources ?? []
        var seen = Set(merged.map { $0.url })
        for s in sources where !seen.contains(s.url) {
            merged.append(s)
            seen.insert(s.url)
        }
        arr[i].sources = merged
        messages[chatId] = arr
    }

    /// Attach a sent file (from send_file) onto the streaming assistant message so a
    /// downloadable file card renders under the answer. Dedupe by id.
    private func attachFile(chatId: String, msgId: String, file: SentFile) {
        guard var arr = messages[chatId],
              let i = arr.lastIndex(where: { $0.id == msgId }) else { return }
        var merged = arr[i].files ?? []
        guard !merged.contains(where: { $0.id == file.id }) else { return }
        merged.append(file)
        arr[i].files = merged
        messages[chatId] = arr
    }

    // MARK: - SSE loop

    private func streamRun(chatId: String, runId: String, assistantMsgId: String, client: HermesClient) async {
        // Keep the run going if the screen locks / app backgrounds mid-stream.
        // The background task covers the first ~30s; the silent audio keep-alive
        // extends it for as long as the run streams (voice mode is already kept
        // alive by its own mic session, so the keep-alive no-ops there).
        let bgTask = UIApplication.shared.beginBackgroundTask(withName: "hermes.run")
        BackgroundAudioKeepAlive.shared.begin()
        defer {
            BackgroundAudioKeepAlive.shared.end()
            if bgTask != .invalid { UIApplication.shared.endBackgroundTask(bgTask) }
        }

        let req = client.runEventsRequest(runId: runId)
        let stream = SSEStream(urlRequest: req)
        let t0Stream = Date()
        var firstDeltaLogged = false

        // Coalesce streaming deltas. Applying every token to the @Observable model
        // re-renders ChatView (recomputing displayItems) and rebuilds the message
        // LazyVStack + re-parses Markdown on EVERY token — which saturates the main
        // thread and has watchdog-killed the app mid-stream (esp. when backgrounded,
        // where iOS couldn't suspend because layout was in flight). Buffer tokens and
        // flush at ~20 Hz; always flush before a structural event so order/text stay
        // correct and no trailing tokens are lost.
        var pendingDelta = ""
        var lastFlush = Date()
        func flushPending() {
            guard !pendingDelta.isEmpty else { return }
            if UIApplication.shared.applicationState == .active {
                let deferred = deferredMessageDeltas.removeValue(forKey: assistantMsgId) ?? ""
                appendDelta(chatId: chatId, msgId: assistantMsgId, delta: deferred + pendingDelta)
            } else {
                deferredMessageDeltas[assistantMsgId, default: ""] += pendingDelta
            }
            pendingDelta = ""
            lastFlush = Date()
        }

        do {
            for try await event in stream.events() {
                guard isStreaming[chatId] == true else { break }
                switch event {
                case .messageDelta(_, let delta):
                    runsWithOutput.insert(runId)
                    if !firstDeltaLogged {
                        firstDeltaLogged = true
                        let e = Date().timeIntervalSince(t0Stream)
                        NSLog("HERMES⏱ first-delta  +%.3fs  len=%d  %@",
                              e, delta.count,
                              String(delta.prefix(40)).replacingOccurrences(of: "\n", with: "↵"))
                        TimingReporter.mark("first-delta",
                            detail: "sseOpen+\(String(format:"%.3f",e))s len=\(delta.count)")
                    }
                    pendingDelta += delta
                    // Only push to the UI while foregrounded. Backgrounded, keep
                    // buffering — driving the message LazyVStack's layout off-screen
                    // is wasted work that the watchdog has killed mid-stream (every
                    // hang crash was procRole=Background). The buffer is applied on the
                    // next foreground delta and always on completion (flushPending in
                    // the terminal cases), so no text is lost.
                    if UIApplication.shared.applicationState == .active,
                       Date().timeIntervalSince(lastFlush) >= 0.05 {
                        flushPending()
                    }

                case .messageComplete:
                    flushPending()
                    finalizeMessage(chatId: chatId, msgId: assistantMsgId)

                case .toolStarted(_, let tool):
                    flushPending()
                    var m = ChatMessage(id: "t-\(UUID().uuidString)", type: .toolEvent)
                    m.tool = tool
                    addMessage(chatId: chatId, message: m)

                case .toolCompleted(_, let toolName, let tcId, let duration, let summary, let sources, let file, let isError):
                    flushPending()
                    completeTool(chatId: chatId, toolName: toolName, toolCallId: tcId,
                                 duration: duration, summary: summary, isError: isError)
                    if let sources, !sources.isEmpty {
                        attachSources(chatId: chatId, msgId: assistantMsgId, sources: sources)
                    }
                    if let file {
                        attachFile(chatId: chatId, msgId: assistantMsgId, file: file)
                    }

                case .approvalRequired(_, let approval):
                    flushPending()
                    var m = ChatMessage(id: "apr-\(UUID().uuidString)", type: .approval)
                    m.approval = approval
                    addMessage(chatId: chatId, message: m)

                case .runCompleted:
                    flushPending()
                    finalizeRun(chatId: chatId)

                case .runFailed(_, let err):
                    flushPending()
                    addMessage(chatId: chatId, message: ChatMessage(
                        id: "err-\(UUID().uuidString)", type: .systemStatus, content: "Run failed: \(err)"))
                    Haptics.notification(.error)
                    finalizeRun(chatId: chatId)

                case .runStopped:
                    flushPending()
                    finalizeRun(chatId: chatId)

                default: break
                }
            }
            // Safety net: if the stream exhausted without a terminal event, clean up.
            flushPending()
            if isStreaming[chatId] == true { finalizeRun(chatId: chatId) }
        } catch {
            flushPending()
            if !Task.isCancelled {
                addMessage(chatId: chatId, message: ChatMessage(
                    id: "err-\(UUID().uuidString)", type: .systemStatus,
                    content: "Stream error: \(error.localizedDescription)"))
            }
            finalizeRun(chatId: chatId)
        }
    }

    // MARK: - Image generation (/image command)

    func generateImage(chatId: String, prompt: String) async {
        guard let client = settings?.client else { return }
        guard await promoteDraftIfNeeded(chatId: chatId, client: client) else { return }

        let userMsg = ChatMessage(id: "u-\(UUID().uuidString)", type: .user, content: "/image \(prompt)")
        addMessage(chatId: chatId, message: userMsg)
        Haptics.impact(.medium)

        var placeholder = ChatMessage(id: "img-\(UUID().uuidString)", type: .assistant, streaming: true)
        placeholder.content = ""
        addMessage(chatId: chatId, message: placeholder)
        isStreaming[chatId] = true

        do {
            let result = try await client.generateImage(prompt: prompt)
            guard var arr = messages[chatId],
                  let idx = arr.lastIndex(where: { $0.id == placeholder.id }) else { return }
            arr[idx].content = result.hasPrefix("data:") || result.hasPrefix("http")
                ? "![](\(result))"
                : result
            arr[idx].streaming = false
            arr[idx].status = .completed
            messages[chatId] = arr
            Haptics.notification(.success)
        } catch {
            guard var arr = messages[chatId],
                  let idx = arr.lastIndex(where: { $0.id == placeholder.id }) else { return }
            arr[idx].content = "Image generation failed: \(error.localizedDescription)"
            arr[idx].streaming = false
            arr[idx].status = .failed
            messages[chatId] = arr
            Haptics.notification(.error)
        }
        isStreaming[chatId] = false
        Task { await persistMessages(chatId: chatId) }
        maybeNotify(chatId: chatId)
    }

    private func finalizeRun(chatId: String) {
        if let runId = runningRunId[chatId] {
            runsWithOutput.remove(runId)
        }
        isStreaming[chatId] = false
        runningRunId.removeValue(forKey: chatId)
        // Defensively clear any assistant message still flagged streaming. The
        // server may end a run via run_completed (or the connection may drop)
        // without a preceding message_complete, which would otherwise leave the
        // bubble stuck showing the typing indicator with no Copy action.
        if var arr = messages[chatId] {
            var mutated = false
            for i in arr.indices where arr[i].streaming == true {
                arr[i].streaming = false
                if arr[i].status != .failed { arr[i].status = .completed }
                mutated = true
            }
            // Also clear any tool spinner still running — a missed tool.completed
            // event would otherwise leave the timeline spinning after the run.
            for i in arr.indices where arr[i].type == .toolEvent && arr[i].tool != nil && arr[i].tool?.completed != true {
                arr[i].tool?.completed = true
                mutated = true
            }
            if mutated { messages[chatId] = arr }
        }
        Task { await persistMessages(chatId: chatId) }
        maybeNotify(chatId: chatId)
        Haptics.notification(.success)
    }

    private func maybeNotify(chatId: String) {
        guard settings?.backgroundNotifications == true else { return }
        guard UIApplication.shared.applicationState != .active else { return }

        let chatTitle = chats.first(where: { $0.id == chatId })?.title ?? "Hermes"
        let preview = messages[chatId]?
            .filter { $0.type == .assistant }
            .compactMap(\.content)
            .last
            .map { String($0.prefix(120)) } ?? ""

        let content = UNMutableNotificationContent()
        content.title = chatTitle
        content.body = preview.isEmpty ? "Response ready" : preview
        content.sound = .default

        let req = UNNotificationRequest(
            identifier: "hermes-run-\(chatId)-\(Date().timeIntervalSince1970)",
            content: content,
            trigger: nil  // deliver immediately
        )
        UNUserNotificationCenter.current().add(req)
    }

    private func persistMessages(chatId: String) async {
        guard let client = settings?.client,
              let msgs = messages[chatId],
              !(chats.first(where: { $0.id == chatId })?.isTemporary ?? false) else { return }
        var stable = msgs.filter { $0.streaming != true }
        for index in stable.indices {
            if let deferred = deferredMessageDeltas[stable[index].id], !deferred.isEmpty {
                stable[index].content = (stable[index].content ?? "") + deferred
            }
        }
        try? await client.saveMessages(chatId, messages: stable)
    }

    // MARK: - Helpers

    private func update(chatId: String, block: (inout UiChat) -> Void) {
        guard let idx = chats.firstIndex(where: { $0.id == chatId }) else { return }
        var c = chats[idx]; block(&c); chats[idx] = c
        persistChatCache()
    }

    private func refreshChatMetadataFromMessages(chatId: String, messages loadedMessages: [ChatMessage]) {
        let visibleMessages = loadedMessages.filter {
            ($0.type == .user || $0.type == .assistant) &&
            $0.streaming != true &&
            $0.content?.isEmpty == false
        }
        guard !visibleMessages.isEmpty else { return }
        update(chatId: chatId) {
            $0.createdAt = visibleMessages.first?.createdAt ?? $0.createdAt
            $0.updatedAt = visibleMessages.last?.createdAt ?? $0.updatedAt
            if let preview = visibleMessages.last?.content {
                $0.lastMessagePreview = String(UiChat.withoutInternalMarkers(preview).prefix(100))
            }
        }
    }

    private func loadCachedChats() {
        guard let data = UserDefaults.standard.data(forKey: chatCacheKey),
              let cached = try? JSONDecoder().decode([UiChat].self, from: data) else { return }
        chats = cached.filter { !$0.isTemporary }
    }

    private func persistChatCache() {
        let cached = chats.filter { !draftChatIds.contains($0.id) && !$0.isTemporary }
        guard let data = try? JSONEncoder().encode(cached) else { return }
        UserDefaults.standard.set(data, forKey: chatCacheKey)
    }

    private func sortChats() {
        chats.sort {
            if $0.pinned != $1.pinned { return $0.pinned && !$1.pinned }
            return $0.updatedAt > $1.updatedAt
        }
    }

    private func buildHistory(chatId: String, excludeId: String) -> [HistoryMessage] {
        guard let msgs = messages[chatId] else { return [] }
        return msgs.compactMap { msg -> HistoryMessage? in
            guard msg.id != excludeId else { return nil }
            switch msg.type {
            case .user:
                let content = msg.content ?? ""
                return HistoryMessage(
                    role: "user",
                    content: msg.voiceMode == true ? "[VOICE_MODE]\n\(content)" : content
                )
            case .assistant where msg.status == .completed:
                return HistoryMessage(role: "assistant", content: msg.content ?? "")
            default: return nil
            }
        }
    }

    /// Requests that explicitly ask for research—or inherently depend on live
    /// information—must use web_search. This is intentionally conservative so
    /// ordinary timeless questions retain the local model's low latency.
    private static func requiresWebSearch(_ text: String) -> Bool {
        let value = text.lowercased()
        let asksForWeb = [
            "search the internet", "search online", "search the web",
            "internet research", "web research", "research online",
            "look it up", "look this up", "check online", "check the internet",
            "do some research", "browse the web", "browse online"
        ].contains { value.contains($0) }
        if asksForWeb { return true }

        let currentSignals = [
            "latest", "most recent", "right now", "currently", "today",
            "tonight", "this week", "upcoming", "current price",
            "current weather", "weather in", "latest news", "current news"
        ]
        return currentSignals.contains { value.contains($0) }
    }

    private func buildMultimodalParts(text: String, images: [ChatAttachment]) -> [RunInputPart] {
        var parts: [RunInputPart] = [RunInputPart(type: .text, text: text)]
        for img in images where img.type == .image {
            if let url = img.dataUrl {
                parts.append(RunInputPart(type: .image_url, imageUrl: RunInputPart.ImageUrl(url: url)))
            }
        }
        return parts
    }

    // MARK: - Grouped chat sections for sidebar

    struct ChatGroup: Identifiable {
        var id: String
        var title: String
        var chats: [UiChat]
    }

    var ungroupedChats: [ChatGroup] {
        let cal = Calendar.current
        let todayStart = cal.startOfDay(for: Date())
        var pinned: [UiChat] = []
        var today: [UiChat] = []
        var yesterday: [UiChat] = []
        var last7: [UiChat] = []
        var older: [UiChat] = []

        for chat in chats where !chat.archived && !chat.isTemporary && chat.projectId == nil {
            if chat.pinned { pinned.append(chat); continue }
            let chatDayStart = cal.startOfDay(for: chat.updatedAt)
            let days = cal.dateComponents([.day], from: chatDayStart, to: todayStart).day ?? 0
            switch days {
            case 0: today.append(chat)
            case 1: yesterday.append(chat)
            case 2...7: last7.append(chat)
            default: older.append(chat)
            }
        }

        pinned.sort { $0.updatedAt > $1.updatedAt }
        today.sort { $0.updatedAt > $1.updatedAt }
        yesterday.sort { $0.updatedAt > $1.updatedAt }
        last7.sort { $0.updatedAt > $1.updatedAt }
        older.sort { $0.updatedAt > $1.updatedAt }

        var groups: [ChatGroup] = []
        if !pinned.isEmpty    { groups.append(.init(id: "pinned",     title: "Pinned",          chats: pinned)) }
        if !today.isEmpty     { groups.append(.init(id: "today",      title: "Today",           chats: today)) }
        if !yesterday.isEmpty { groups.append(.init(id: "yesterday",  title: "Yesterday",       chats: yesterday)) }
        if !last7.isEmpty     { groups.append(.init(id: "last7",      title: "Previous 7 Days", chats: last7)) }
        if !older.isEmpty     { groups.append(.init(id: "older",      title: "Older",           chats: older)) }
        return groups
    }

    func chatsFor(projectId: String) -> [UiChat] {
        chats
            .filter { !$0.archived && $0.projectId == projectId }
            .sorted { $0.updatedAt > $1.updatedAt }
    }

    // MARK: - Export

    func exportMarkdown(chatId: String) -> String {
        let chat = chats.first { $0.id == chatId }
        var lines = ["# \(chat?.title ?? "Chat")", ""]
        for msg in messages[chatId] ?? [] {
            switch msg.type {
            case .user:
                lines.append("**You**\n\(msg.content ?? "")\n")
            case .assistant:
                lines.append("**Hermes**\n\(msg.content ?? "")\n")
            default: break
            }
        }
        return lines.joined(separator: "\n")
    }

    func exportJSON(chatId: String) -> String {
        let msgs = messages[chatId] ?? []
        let data = (try? JSONEncoder().encode(msgs)) ?? Data()
        return String(data: data, encoding: .utf8) ?? "[]"
    }
}
