import SwiftUI

// MARK: - Display item (groups consecutive tool events)

enum DisplayItem: Identifiable {
    case single(ChatMessage)
    case toolGroup([ChatMessage])

    var id: String {
        switch self {
        case .single(let m):       return m.id
        case .toolGroup(let msgs): return "tg-\(msgs.first?.id ?? UUID().uuidString)"
        }
    }
}

// MARK: - ChatView

struct ChatView: View {
    @Environment(SettingsStore.self) private var settings
    @Environment(ChatStore.self) private var chatStore
    let chatId: String

    @State private var showExportSheet = false
    @State private var exportText: String = ""
    @State private var showToolsSheet = false
    @State private var showModelSheet = false

    private var chat: UiChat? { chatStore.chats.first { $0.id == chatId } }
    private var isTemporary: Bool { chat?.isTemporary ?? false }
    private var isLoadingMessages: Bool { chatStore.isLoadingMessages(chatId: chatId) }
    // Watermark only for a brand-new (draft) chat — never for an existing chat
    // whose messages are still loading (which would briefly flash the image).
    // Flips false the instant the first message promotes the draft, so it slides
    // up exactly when you send.
    private var showWatermark: Bool { chatStore.isDraft(chatId) }

    private var displayItems: [DisplayItem] {
        var result: [DisplayItem] = []
        var toolBuffer: [ChatMessage] = []
        for msg in chatStore.messages[chatId] ?? [] {
            if msg.type == .toolEvent {
                toolBuffer.append(msg)
            } else {
                if !toolBuffer.isEmpty {
                    result.append(.toolGroup(toolBuffer))
                    toolBuffer = []
                }
                result.append(.single(msg))
            }
        }
        if !toolBuffer.isEmpty { result.append(.toolGroup(toolBuffer)) }
        return result
    }

    var body: some View {
        VStack(spacing: 0) {
            // ScrollViewReader lets us jump to the bottom imperatively — without
            // .defaultScrollAnchor(.bottom), which forces SwiftUI to measure the
            // total content height (ALL items) so it knows where "bottom" is.
            // That measurement defeats LazyVStack and blocks the main thread for
            // several seconds on long chats, causing 0x8BADF00D watchdog kills.
            // scrollTo fires only on discrete events (new message, chat open),
            // so it never re-enters the AttributeGraph update loop.
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(displayItems) { item in
                            switch item {
                            case .single(let msg):
                                MessageView(message: msg, chatId: chatId)
                                    .equatable()
                                    .environment(settings)
                                    .environment(chatStore)
                                    .id(msg.id)
                            case .toolGroup(let tools):
                                ToolTimelineView(tools: tools)
                                    .equatable()
                                    .id(item.id)
                            }
                        }
                    }
                    .padding(.vertical, 8)
                }
                .onChange(of: displayItems.count) { _, _ in
                    if let id = displayItems.last?.id {
                        proxy.scrollTo(id, anchor: .bottom)
                    }
                }
                .onAppear {
                    if let id = displayItems.last?.id {
                        proxy.scrollTo(id, anchor: .bottom)
                    }
                }
                // Faded app-icon watermark on a brand-new chat.
                .overlay {
                    if showWatermark {
                        VStack(spacing: 8) {
                            Image("AppLogo")
                                .renderingMode(.template)
                                .resizable()
                                .aspectRatio(contentMode: .fit)
                                .frame(width: 240, height: 240)
                                .foregroundStyle(.secondary)
                                .opacity(0.30)
                            Text("How can I help you?")
                                .font(.title2.weight(.semibold))
                                .foregroundStyle(.secondary)
                        }
                        .allowsHitTesting(false)
                        .transition(.move(edge: .top).combined(with: .opacity))
                    }
                }
                .overlay {
                    if isLoadingMessages {
                        VStack(spacing: 10) {
                            ProgressView()
                            Text("Loading conversation...")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                        }
                        .padding(18)
                        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 8))
                    }
                }
                .opacity(isLoadingMessages ? 0.45 : 1)
                .animation(.easeInOut(duration: 0.45), value: showWatermark)
                .animation(.easeInOut(duration: 0.2), value: isLoadingMessages)
            }

            ComposerView(chatId: chatId)
                .environment(settings)
                .environment(chatStore)
        }
        .navigationTitle(chat?.title ?? "Chat")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .navigationBarTrailing) {
                if isTemporary {
                    Label("Temporary", systemImage: "clock.arrow.trianglehead.counterclockwise.rotate.90")
                        .labelStyle(.iconOnly)
                        .foregroundStyle(.orange)
                        .font(.caption)
                }
                // New chat — sits just left of the ⋯ menu.
                Button {
                    Task { _ = await chatStore.newChat() }
                } label: {
                    Image(systemName: "square.and.pencil")
                }
                Menu {
                    Button {
                        showToolsSheet = true
                    } label: {
                        Label(chatStore.chatToolsetOverride[chatId] != nil ? "Tools (chat override)" : "Tools for this chat",
                              systemImage: "wrench.and.screwdriver")
                    }
                    Button {
                        showModelSheet = true
                    } label: {
                        Label(chat?.modelId?.isEmpty == false ? "Model (chat override)" : "Model for this chat",
                              systemImage: "brain")
                    }

                    Button {
                        exportText = chatStore.exportMarkdown(chatId: chatId)
                        showExportSheet = true
                    } label: { Label("Export Markdown", systemImage: "doc.text") }

                    Button {
                        exportText = chatStore.exportJSON(chatId: chatId)
                        showExportSheet = true
                    } label: { Label("Export JSON", systemImage: "curlybraces") }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }
        }
        .sheet(isPresented: $showExportSheet) {
            ExportSheet(text: exportText, chatTitle: chat?.title ?? "Chat")
        }
        .sheet(isPresented: $showToolsSheet) {
            ChatToolsOverrideView(chatId: chatId)
                .environment(settings)
                .environment(chatStore)
        }
        .sheet(isPresented: $showModelSheet) {
            ChatModelOverrideView(chatId: chatId)
                .environment(settings)
                .environment(chatStore)
        }
        // onAppear (not .task) so the load isn't cancelled when this view is torn
        // down during navigation — the fetch is owned by the store and survives.
        .onAppear {
            chatStore.loadMessagesIfNeeded(chatId: chatId)
        }
    }
}

// MARK: - ExportSheet

private struct ExportSheet: View {
    let text: String
    let chatTitle: String
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                Text(text)
                    .font(.system(.caption, design: .monospaced))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
                    .textSelection(.enabled)
            }
            .navigationTitle("Export: \(chatTitle)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Done") { dismiss() }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    ShareLink(item: text) {
                        Image(systemName: "square.and.arrow.up")
                    }
                }
            }
        }
    }
}

// MARK: - ChatToolsOverrideView
// Per-chat toolset override. When off, the chat uses the universal api_server
// config. When on, this chat's runs send enabled_toolsets to override it.

struct ChatToolsOverrideView: View {
    @Environment(SettingsStore.self) private var settings
    @Environment(ChatStore.self) private var chatStore
    @Environment(\.dismiss) private var dismiss
    let chatId: String

    @State private var isOverriding = false
    @State private var selected: Set<String> = []
    @State private var loaded = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Toggle("Use chat-specific tools", isOn: $isOverriding)
                } footer: {
                    Text(isOverriding
                         ? "This chat overrides the universal toolset selection. Changes apply on the next message."
                         : "This chat uses the universal toolset selection from Settings → Tools.")
                }

                if isOverriding {
                    if settings.availableTools.isEmpty {
                        Section { Text("No toolsets available.").foregroundStyle(.secondary) }
                    } else {
                        Section("Toolsets for this chat") {
                            ForEach(settings.availableTools) { tool in
                                Toggle(isOn: Binding(
                                    get: { selected.contains(tool.name) },
                                    set: { on in
                                        if on { selected.insert(tool.name) } else { selected.remove(tool.name) }
                                    }
                                )) {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(tool.label ?? tool.name)
                                        if !tool.tools.isEmpty {
                                            Text(tool.tools.joined(separator: ", "))
                                                .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                        }
                                    }
                                }
                                .disabled(!tool.available)
                            }
                        }
                    }
                }
            }
            .navigationTitle("Chat Tools")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        if isOverriding {
                            chatStore.chatToolsetOverride[chatId] = Array(selected)
                        } else {
                            chatStore.chatToolsetOverride.removeValue(forKey: chatId)
                        }
                        Haptics.notification(.success)
                        dismiss()
                    }
                }
            }
            .task {
                guard !loaded else { return }
                await settings.fetchTools()
                if let override = chatStore.chatToolsetOverride[chatId] {
                    isOverriding = true
                    selected = Set(override)
                } else {
                    selected = settings.enabledTools
                }
                loaded = true
            }
        }
    }
}

// MARK: - ChatModelOverrideView

struct ChatModelOverrideView: View {
    @Environment(SettingsStore.self) private var settings
    @Environment(ChatStore.self) private var chatStore
    @Environment(\.dismiss) private var dismiss
    let chatId: String

    @State private var isOverriding = false
    @State private var provider = ""
    @State private var model = ""

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Toggle("Use chat-specific model", isOn: $isOverriding)
                } footer: {
                    Text(isOverriding
                         ? "This chat uses its own model. Other iOS chats and the Hermes default are unchanged."
                         : "This chat uses the iOS default model from Settings.")
                }

                if isOverriding {
                    if settings.availableModelProviders.isEmpty {
                        Section { Text("No models available.").foregroundStyle(.secondary) }
                    } else {
                        Section("Provider") {
                            Picker("Provider", selection: $provider) {
                                ForEach(settings.availableModelProviders) { item in
                                    Text(item.name).tag(item.id)
                                }
                            }
                        }
                        Section("Model") {
                            Picker("Model", selection: $model) {
                                ForEach(settings.models(for: provider)) { item in
                                    Text(item.name).tag(item.id)
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("Chat Model")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        Task {
                            await chatStore.setChatModelOverride(
                                chatId,
                                provider: isOverriding ? provider : nil,
                                modelId: isOverriding ? model : nil
                            )
                            Haptics.notification(.success)
                            dismiss()
                        }
                    }
                    .disabled(isOverriding && (provider.isEmpty || model.isEmpty))
                }
            }
            .task {
                await settings.fetchModels()
                if let chat = chatStore.chats.first(where: { $0.id == chatId }),
                   let chatProvider = chat.modelProvider, !chatProvider.isEmpty,
                   let chatModel = chat.modelId, !chatModel.isEmpty {
                    isOverriding = true
                    provider = chatProvider
                    model = chatModel
                } else {
                    provider = settings.selectedProvider
                    model = settings.selectedModel
                }
                normalizeModel()
            }
            .onChange(of: provider) { _, _ in normalizeModel() }
        }
    }

    private func normalizeModel() {
        let models = settings.models(for: provider)
        if !models.contains(where: { $0.id == model }) {
            model = models.first?.id ?? ""
        }
    }
}
