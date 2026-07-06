import SwiftUI

struct SidebarView: View {
    @Environment(SettingsStore.self) private var settings
    @Environment(ChatStore.self) private var chatStore
    @Binding var showSettings: Bool
    @State private var searchText = ""
    @State private var renamingChatId: String?
    @State private var renameText = ""
    @State private var showNewProject = false
    @State private var movingChatId: String?
    @State private var showTrash = false

    var body: some View {
        List(selection: Binding(
            get: { chatStore.activeChatId },
            set: { chatStore.activeChatId = $0 }
        )) {
            if searchText.isEmpty {
                projectSections
                ungroupedSections
            } else {
                searchResults
            }
        }
        .listStyle(.sidebar)
        .searchable(text: $searchText, prompt: "Search chats")
        .navigationTitle("Hermes")
        .toolbar {
            ToolbarItem(placement: .navigationBarLeading) {
                Button { showSettings = true } label: { Image(systemName: "gearshape") }
            }
            ToolbarItemGroup(placement: .navigationBarTrailing) {
                Button {
                    showTrash = true
                } label: {
                    Image(systemName: "trash")
                }

                // Tap = new chat; long-press = New Project. Shows an icon + "Chat"
                // label in the toolbar pill. (Search lives in the bottom search bar.)
                Menu {
                    Button { showNewProject = true } label: {
                        Label("New Project", systemImage: "folder.badge.plus")
                    }
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "square.and.pencil")
                        Text("Chat")
                    }
                    .padding(.horizontal, 8)
                } primaryAction: {
                    Task { _ = await chatStore.newChat() }
                }
            }
        }
        .sheet(isPresented: $showTrash) {
            TrashSheet()
                .environment(chatStore)
        }
        .sheet(isPresented: $showNewProject) {
            NewProjectSheet { name, color in
                Task { await chatStore.createProject(name: name, color: color) }
            }
        }
        .sheet(item: Binding(
            get: { movingChatId.map { MovingChat(id: $0) } },
            set: { movingChatId = $0?.id }
        )) { mc in
            MoveToProjectSheet(chatId: mc.id)
                .environment(chatStore)
        }
        .task {
            if chatStore.chats.isEmpty { await chatStore.loadAll() }
        }
    }

    // MARK: - Sections

    @ViewBuilder private var projectSections: some View {
        if !chatStore.projects.isEmpty {
            Section("Projects") {
                ForEach(chatStore.projects) { project in
                    ProjectDisclosureGroup(
                        project: project,
                        renamingChatId: $renamingChatId,
                        renameText: $renameText,
                        movingChatId: $movingChatId
                    )
                    .environment(chatStore)
                }
            }
        }
    }

    @ViewBuilder private var ungroupedSections: some View {
        ForEach(chatStore.ungroupedChats) { group in
            Section(group.title) {
                ForEach(group.chats) { chat in
                    ChatRowView(
                        chat: chat,
                        isRenaming: renamingChatId == chat.id,
                        renameText: $renameText,
                        onRenameSubmit: { Task { await chatStore.renameChat(chat.id, title: renameText) }; renamingChatId = nil },
                        onRenameCancel: { renamingChatId = nil }
                    )
                    .tag(chat.id)
                    .chatSwipeActions(chat: chat, chatStore: chatStore, renamingChatId: $renamingChatId, renameText: $renameText, movingChatId: $movingChatId)
                    .chatContextMenu(chat: chat, chatStore: chatStore, renamingChatId: $renamingChatId, renameText: $renameText, movingChatId: $movingChatId)
                }
            }
        }
    }

    @ViewBuilder private var searchResults: some View {
        let results = chatStore.chats.filter {
            !$0.archived &&
            ($0.title.localizedCaseInsensitiveContains(searchText) ||
             $0.lastMessagePreview.localizedCaseInsensitiveContains(searchText))
        }
        if results.isEmpty {
            Text("No results").foregroundStyle(.secondary)
        } else {
            ForEach(results) { chat in
                ChatRowView(chat: chat, isRenaming: false, renameText: .constant(""),
                            onRenameSubmit: {}, onRenameCancel: {})
                    .tag(chat.id)
            }
        }
    }
}

// MARK: - ProjectDisclosureGroup

private struct ProjectDisclosureGroup: View {
    @Environment(ChatStore.self) private var chatStore
    let project: Project
    @Binding var renamingChatId: String?
    @Binding var renameText: String
    @Binding var movingChatId: String?
    @State private var expanded = true

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            ForEach(chatStore.chatsFor(projectId: project.id)) { chat in
                ChatRowView(
                    chat: chat,
                    isRenaming: renamingChatId == chat.id,
                    renameText: $renameText,
                    onRenameSubmit: { Task { await chatStore.renameChat(chat.id, title: renameText) }; renamingChatId = nil },
                    onRenameCancel: { renamingChatId = nil }
                )
                .tag(chat.id)
                .chatSwipeActions(chat: chat, chatStore: chatStore, renamingChatId: $renamingChatId, renameText: $renameText, movingChatId: $movingChatId)
                .chatContextMenu(chat: chat, chatStore: chatStore, renamingChatId: $renamingChatId, renameText: $renameText, movingChatId: $movingChatId)
            }
        } label: {
            Label {
                Text(project.name)
            } icon: {
                Image(systemName: "folder.fill")
                    .foregroundStyle(projectColor(project.color))
            }
        }
        .contextMenu {
            Button(role: .destructive) {
                Task { await chatStore.deleteProject(project.id) }
            } label: { Label("Delete Project", systemImage: "trash") }
        }
    }
}

// MARK: - ChatRowView

struct ChatRowView: View {
    let chat: UiChat
    let isRenaming: Bool
    @Binding var renameText: String
    let onRenameSubmit: () -> Void
    let onRenameCancel: () -> Void

    var body: some View {
        if isRenaming {
            TextField("Title", text: $renameText)
                .onSubmit(onRenameSubmit)
                .submitLabel(.done)
        } else {
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    if chat.pinned {
                        Image(systemName: "pin.fill").font(.caption2).foregroundStyle(.orange)
                    }
                    Text(chat.title).font(.body).lineLimit(1)
                    Spacer()
                    Text(chat.createdAt, format: .dateTime.year().month(.abbreviated).day().hour().minute())
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                if !chat.lastMessagePreview.isEmpty {
                    Text(chat.lastMessagePreview)
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
        }
    }
}

// MARK: - View modifiers for swipe actions and context menus

extension View {
    func chatSwipeActions(chat: UiChat, chatStore: ChatStore,
                          renamingChatId: Binding<String?>, renameText: Binding<String>,
                          movingChatId: Binding<String?>) -> some View {
        self
            .swipeActions(edge: .trailing) {
                Button(role: .destructive) {
                    Task { await chatStore.deleteChat(chat.id) }
                } label: { Label("Delete", systemImage: "trash") }

                Button {
                    Task { await chatStore.archiveChat(chat.id) }
                } label: { Label("Archive", systemImage: "archivebox") }
                .tint(.gray)

                Button {
                    Task { await chatStore.pinChat(chat.id, pinned: !chat.pinned) }
                } label: { Label(chat.pinned ? "Unpin" : "Pin", systemImage: chat.pinned ? "pin.slash" : "pin") }
                .tint(.orange)
            }
    }

    func chatContextMenu(chat: UiChat, chatStore: ChatStore,
                         renamingChatId: Binding<String?>, renameText: Binding<String>,
                         movingChatId: Binding<String?>) -> some View {
        self.contextMenu {
            Button {
                renamingChatId.wrappedValue = chat.id
                renameText.wrappedValue = chat.title
            } label: { Label("Rename", systemImage: "pencil") }

            Button {
                Task { await chatStore.pinChat(chat.id, pinned: !chat.pinned) }
            } label: { Label(chat.pinned ? "Unpin" : "Pin", systemImage: chat.pinned ? "pin.slash" : "pin") }

            if !chatStore.projects.isEmpty {
                Button { movingChatId.wrappedValue = chat.id } label: {
                    Label("Move to Project…", systemImage: "folder")
                }
            }

            Button {
                Task { await chatStore.archiveChat(chat.id) }
            } label: { Label("Archive", systemImage: "archivebox") }

            Divider()
            Button(role: .destructive) {
                Task { await chatStore.deleteChat(chat.id) }
            } label: { Label("Delete", systemImage: "trash") }
        }
    }
}

// MARK: - NewProjectSheet

private struct NewProjectSheet: View {
    let onCreate: (String, String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var selectedColor = "blue"

    var body: some View {
        NavigationStack {
            Form {
                Section("Name") {
                    TextField("Project name", text: $name)
                }
                Section("Color") {
                    LazyVGrid(columns: Array(repeating: .init(.flexible()), count: 4), spacing: 12) {
                        ForEach(Project.colors, id: \.self) { color in
                            Circle()
                                .fill(projectColor(color))
                                .frame(width: 36, height: 36)
                                .overlay {
                                    if selectedColor == color {
                                        Circle().stroke(.primary, lineWidth: 2).padding(2)
                                    }
                                }
                                .onTapGesture { selectedColor = color }
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
            .navigationTitle("New Project")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Create") {
                        guard !name.isEmpty else { return }
                        onCreate(name, selectedColor)
                        dismiss()
                    }
                    .bold()
                    .disabled(name.isEmpty)
                }
            }
        }
    }
}

// MARK: - MoveToProjectSheet

private struct MoveToProjectSheet: View {
    @Environment(ChatStore.self) private var chatStore
    @Environment(\.dismiss) private var dismiss
    let chatId: String

    var body: some View {
        NavigationStack {
            List {
                Button("No Project") {
                    Task { await chatStore.moveChatToProject(chatId, projectId: nil) }
                    dismiss()
                }
                .foregroundStyle(.secondary)

                ForEach(chatStore.projects) { project in
                    Button {
                        Task { await chatStore.moveChatToProject(chatId, projectId: project.id) }
                        dismiss()
                    } label: {
                        Label {
                            Text(project.name)
                        } icon: {
                            Image(systemName: "folder.fill").foregroundStyle(projectColor(project.color))
                        }
                    }
                    .foregroundStyle(.primary)
                }
            }
            .navigationTitle("Move to Project")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) { Button("Cancel") { dismiss() } }
            }
        }
    }
}

// MARK: - TrashSheet

private struct TrashSheet: View {
    @Environment(ChatStore.self) private var chatStore
    @Environment(\.dismiss) private var dismiss
    @State private var confirmEmptyTrash = false

    var body: some View {
        NavigationStack {
            List {
                if chatStore.trashedChats.isEmpty {
                    Text("Trash is empty")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(chatStore.trashedChats) { chat in
                        HStack {
                            ChatRowView(
                                chat: chat,
                                isRenaming: false,
                                renameText: .constant(""),
                                onRenameSubmit: {},
                                onRenameCancel: {}
                            )
                            Button {
                                Task { await chatStore.restoreChat(chat.id) }
                            } label: {
                                Image(systemName: "arrow.uturn.backward")
                            }
                            .buttonStyle(.borderless)
                        }
                        .swipeActions(edge: .trailing) {
                            Button {
                                Task { await chatStore.restoreChat(chat.id) }
                            } label: {
                                Label("Restore", systemImage: "arrow.uturn.backward")
                            }
                            .tint(.blue)
                        }
                        .contextMenu {
                            Button {
                                Task { await chatStore.restoreChat(chat.id) }
                            } label: {
                                Label("Restore", systemImage: "arrow.uturn.backward")
                            }
                        }
                    }
                }
            }
            .navigationTitle("Trash")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Done") { dismiss() }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Empty", role: .destructive) {
                        confirmEmptyTrash = true
                    }
                    .disabled(chatStore.trashedChats.isEmpty)
                }
            }
            .confirmationDialog(
                "Permanently delete all chats in Trash?",
                isPresented: $confirmEmptyTrash,
                titleVisibility: .visible
            ) {
                Button("Empty Trash", role: .destructive) {
                    Task { await chatStore.emptyTrash() }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This removes them from Hermes and the iOS channel database.")
            }
            .task {
                await chatStore.loadTrash()
            }
        }
    }
}

// MARK: - Helpers

func projectColor(_ name: String) -> Color {
    switch name {
    case "blue":   return .blue
    case "green":  return .green
    case "purple": return .purple
    case "orange": return .orange
    case "red":    return .red
    case "pink":   return .pink
    case "yellow": return .yellow
    case "gray":   return .gray
    default:       return .blue
    }
}

private struct MovingChat: Identifiable { var id: String }
