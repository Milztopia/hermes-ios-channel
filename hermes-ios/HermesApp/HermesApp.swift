import SwiftUI
import UserNotifications

@main
struct HermesApp: App {
    @State private var settings = SettingsStore()
    @State private var chatStore = ChatStore()
    @State private var voice = VoiceCoordinator()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(settings)
                .environment(chatStore)
                .environment(voice)
                .onChange(of: scenePhase) { _, phase in
                    if phase == .active {
                        chatStore.flushDeferredUIUpdates()
                    } else if phase == .background {
                        // Free the 400MB+ Kokoro model weights when backgrounded.
                        // With the model mapped, background scene-update watchdog
                        // checks trigger page-fault storms that kill the app (0x8BADF00D).
                        // loadIfNeeded() reloads it transparently on next voice use.
                        Task { KokoroService.shared.unloadIfIdle() }
                    }
                }
                .task {
                    chatStore.attach(settings: settings)
                    voice.preloadSTT(settings: settings)   // warm up on-device Whisper at launch
                    if settings.ttsEngine == .kokoro {     // warm up on-device Kokoro too
                        Task { await KokoroService.shared.loadIfNeeded() }
                    }
                    // Request notification permission in the background so launch
                    // is never held behind the system prompt path.
                    Task {
                        _ = try? await UNUserNotificationCenter.current()
                            .requestAuthorization(options: [.alert, .sound, .badge])
                    }
                    if settings.client != nil {
                        async let serverSettings: Void = settings.loadFromServer()
                        async let models: Void = settings.fetchModels()
                        async let tools: Void = settings.fetchTools()
                        async let chats: Void = chatStore.loadAll()
                        _ = await (serverSettings, models, tools, chats)
                    }
                }
        }
    }
}
