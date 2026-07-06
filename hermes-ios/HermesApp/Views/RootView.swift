import SwiftUI

struct RootView: View {
    @Environment(SettingsStore.self) private var settings
    @Environment(ChatStore.self) private var chatStore
    @Environment(\.horizontalSizeClass) private var hSizeClass
    @State private var showSettings = false
    @State private var columnVisibility = NavigationSplitViewVisibility.doubleColumn

    var body: some View {
        Group {
            if !settings.serverURL.isEmpty {
                mainInterface
            } else {
                ConnectionSetupView()
            }
        }
        .sheet(isPresented: $showSettings) {
            SettingsView()
                .environment(settings)
                .environment(chatStore)
        }
    }

    private var mainInterface: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            SidebarView(showSettings: $showSettings)
                .environment(settings)
                .environment(chatStore)
                .navigationSplitViewColumnWidth(min: 260, ideal: 300, max: 360)
        } detail: {
            if let chatId = chatStore.activeChatId {
                ChatView(chatId: chatId)
                    .environment(settings)
                    .environment(chatStore)
                    .id(chatId)
                    .toolbar {
                        // iPad: sidebar toggle in the detail view when sidebar is hidden
                        if hSizeClass == .regular {
                            ToolbarItem(placement: .navigationBarLeading) {
                                Button {
                                    withAnimation {
                                        columnVisibility = columnVisibility == .detailOnly
                                            ? .doubleColumn : .detailOnly
                                    }
                                } label: {
                                    Image(systemName: "sidebar.left")
                                }
                            }
                        }
                    }
            } else {
                emptyState
            }
        }
        .navigationSplitViewStyle(.balanced)
    }

    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "bubble.left.and.bubble.right")
                .font(.system(size: 52))
                .foregroundStyle(.secondary)
            Text("Select a chat or start a new one")
                .foregroundStyle(.secondary)
            Button("New Chat") {
                Task { _ = await chatStore.newChat() }
            }
            .buttonStyle(.borderedProminent)
        }
        .navigationTitle("Hermes")
    }
}
