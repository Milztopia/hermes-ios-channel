import Foundation
import Observation

// MARK: - Connection settings (device-local, never sent to server)

struct ConnectionSettings {
    var serverURL: String
    var apiKey: String

    static let serverURLKey = "hermes.serverURL"
    static let apiKeyKey = "hermes.apiKey"

    static func load() -> ConnectionSettings {
        ConnectionSettings(
            serverURL: UserDefaults.standard.string(forKey: serverURLKey) ?? "",
            apiKey: UserDefaults.standard.string(forKey: apiKeyKey) ?? ""
        )
    }

    func save() {
        UserDefaults.standard.set(serverURL, forKey: ConnectionSettings.serverURLKey)
        UserDefaults.standard.set(apiKey, forKey: ConnectionSettings.apiKeyKey)
    }

    var isConfigured: Bool { !serverURL.isEmpty }

    var baseURL: URL? { URL(string: serverURL.trimmingCharacters(in: .whitespacesAndNewlines)) }
}

// MARK: - SettingsStore

@Observable
@MainActor
final class SettingsStore {
    // Connection (device-local)
    var serverURL: String {
        didSet {
            UserDefaults.standard.set(serverURL, forKey: ConnectionSettings.serverURLKey)
            rebuildClient()
        }
    }
    var apiKey: String {
        didSet {
            UserDefaults.standard.set(apiKey, forKey: ConnectionSettings.apiKeyKey)
            rebuildClient()
        }
    }

    // AI / app settings (synced with server)
    var systemPrompt: String = "" { didSet { scheduleSyncToServerIfNeeded() } }
    var contextLimit: Int = 0 { didSet { scheduleSyncToServerIfNeeded() } }
    var selectedProvider: String = "" { didSet { scheduleSyncToServerIfNeeded() } }
    var selectedModel: String = "" { didSet { scheduleSyncToServerIfNeeded() } }
    var ttsVoice: String = "" { didSet { scheduleSyncToServerIfNeeded() } }
    var autoSpeak: Bool = true { didSet { scheduleSyncToServerIfNeeded() } }
    var vadSilenceMs: Int = 1200 { didSet { scheduleSyncToServerIfNeeded() } }
    var fontSize: String = "medium" { didSet { scheduleSyncToServerIfNeeded() } }
    var messageDensity: String = "comfortable" { didSet { scheduleSyncToServerIfNeeded() } }
    var backgroundNotifications: Bool = true { didSet { scheduleSyncToServerIfNeeded() } }

    // TTS engine choice (device-local)
    var ttsEngine: TTSEngine {
        didSet { UserDefaults.standard.set(ttsEngine.rawValue, forKey: "hermes.ttsEngine") }
    }
    // On-device (AVSpeech) voice identifier — device-local, not synced to server.
    var onDeviceVoiceId: String {
        didSet { UserDefaults.standard.set(onDeviceVoiceId, forKey: "hermes.onDeviceVoiceId") }
    }
    // On-device Kokoro voice name (e.g. "af_heart") — device-local.
    var kokoroVoice: String {
        didSet { UserDefaults.standard.set(kokoroVoice, forKey: "hermes.kokoroVoice") }
    }
    // STT engine choice (device-local)
    var sttEngine: STTEngine {
        didSet { UserDefaults.standard.set(sttEngine.rawValue, forKey: "hermes.sttEngine") }
    }
    // Initial barge-in preference copied into each newly-created chat. Individual
    // chats can then override it from the voice overlay without changing this.
    var defaultBargeInEnabled: Bool {
        didSet { UserDefaults.standard.set(defaultBargeInEnabled, forKey: "hermes.defaultBargeInEnabled") }
    }
    // Logarithmic microphone gate position, 0...1. Device-local because microphone
    // gain, environment, and preferred speaking volume are specific to this phone.
    var voiceGateLevel: Double {
        didSet { UserDefaults.standard.set(voiceGateLevel, forKey: "hermes.voiceGateLevel") }
    }

    // Available models fetched from server
    var availableModels: [AvailableModel] = []
    var availableModelProviders: [AvailableModelProvider] = []
    var availableHermesVoices: [AvailableVoice] = []
    var defaultHermesVoice: String = ""

    // Available tools fetched from server
    var availableTools: [HermesToolDefinition] = []
    var channelCapabilities: ChannelCapabilities?
    // Tool names the user has chosen to enable (persisted locally)
    var enabledTools: Set<String> = [] {
        didSet {
            let arr = Array(enabledTools)
            if let data = try? JSONEncoder().encode(arr) {
                UserDefaults.standard.set(data, forKey: "hermes.enabledTools")
            }
        }
    }

    // Effective tool list passed to run requests: always include required tools.
    // This is the user's Tools-screen selection (enabled toolsets + required),
    // and it's sent as BOTH `tools` and `enabled_toolsets` so the gateway only
    // injects the schemas for toolsets the user actually turned on — keeping the
    // prompt (and cold-prefill cost) proportional to what's enabled. Returns nil
    // until the tool list has loaded, so we never accidentally send an empty set.
    var effectiveTools: [String]? {
        guard !availableTools.isEmpty else { return nil }
        let required = Set(availableTools.filter(\.required).map(\.name))
        return Array(enabledTools.union(required))
    }

    // Empty means "use the Hermes default voice".
    var effectiveTtsVoice: String {
        return ttsVoice
    }

    var hermesTtsAvailable: Bool {
        channelCapabilities?.voice.hermesTtsAvailable == true || availableHermesVoices.contains(where: \.supported)
    }

    // Connection status
    var connectionState: ConnectionState = .unknown

    enum TTSEngine: String { case server, apple, kokoro }
    enum STTEngine: String { case onDevice, server }
    enum ConnectionState { case unknown, connected, failed(String) }

    private(set) var client: HermesClient?
    private var syncTask: Task<Void, Never>?
    private var shouldAdoptChannelVoiceDefault = false
    private var isApplyingRemoteSettings = false

    init() {
        let conn = ConnectionSettings.load()
        let storedTtsEngine = UserDefaults.standard.string(forKey: "hermes.ttsEngine")
        serverURL = conn.serverURL
        apiKey = conn.apiKey
        ttsEngine = TTSEngine(rawValue: storedTtsEngine ?? "") ?? .apple
        shouldAdoptChannelVoiceDefault = storedTtsEngine == nil
        sttEngine = STTEngine(rawValue: UserDefaults.standard.string(forKey: "hermes.sttEngine") ?? "") ?? .onDevice
        onDeviceVoiceId = UserDefaults.standard.string(forKey: "hermes.onDeviceVoiceId") ?? ""
        kokoroVoice = UserDefaults.standard.string(forKey: "hermes.kokoroVoice") ?? "af_heart"
        defaultBargeInEnabled = UserDefaults.standard.bool(forKey: "hermes.defaultBargeInEnabled")
        voiceGateLevel = UserDefaults.standard.object(forKey: "hermes.voiceGateLevel") as? Double ?? 0.38

        if conn.isConfigured, let url = conn.baseURL {
            client = HermesClient(baseURL: url, apiKey: conn.apiKey)
            TimingReporter.configure(baseURL: url, apiKey: conn.apiKey)
        }

        // Restore persisted enabled tools
        if let data = UserDefaults.standard.data(forKey: "hermes.enabledTools"),
           let arr = try? JSONDecoder().decode([String].self, from: data) {
            enabledTools = Set(arr)
        }
    }

    func testConnection(serverURL testURL: String? = nil, apiKey testKey: String? = nil) async -> Bool {
        let urlString = (testURL ?? serverURL).trimmingCharacters(in: .whitespacesAndNewlines)
        let keyToUse = testKey ?? apiKey
        guard let url = URL(string: urlString) else {
            connectionState = .failed("Invalid URL")
            return false
        }
        let testClient = HermesClient(baseURL: url, apiKey: keyToUse)
        do {
            try await testClient.health()
            connectionState = .connected
            return true
        } catch {
            connectionState = .failed(error.localizedDescription)
            return false
        }
    }

    func loadFromServer() async {
        guard let c = client else { return }
        do {
            let remote = try await c.getSettings()
            applyRemote(remote)
            if let caps = try? await c.getChannelCapabilities() {
                applyChannelCapabilities(caps)
            }
            if let voices = try? await c.listVoices() {
                applyVoices(voices)
            }
            connectionState = .connected
        } catch {
            connectionState = .failed(error.localizedDescription)
        }
    }

    func fetchModels() async {
        guard let c = client else { return }
        do {
            let resp = try await c.listModels()
            availableModels = resp.models
            availableModelProviders = resp.providers ?? []
            normalizeModelSelection(defaultProvider: resp.defaultProvider ?? "", defaultModel: resp.default)
        } catch {
            NSLog("HERMES fetchModels ERROR: \(error)")
        }
    }

    private func normalizeModelSelection(defaultProvider: String, defaultModel: String) {
        guard !availableModelProviders.isEmpty else {
            let modelIds = Set(availableModels.map(\.id))
            if selectedModel.isEmpty || !modelIds.contains(selectedModel) {
                isApplyingRemoteSettings = true
                defer { isApplyingRemoteSettings = false }
                selectedModel = defaultModel
            }
            return
        }
        if selectedProvider.isEmpty || !availableModelProviders.contains(where: { $0.id == selectedProvider }) {
            isApplyingRemoteSettings = true
            defer { isApplyingRemoteSettings = false }
            if !defaultProvider.isEmpty && availableModelProviders.contains(where: { $0.id == defaultProvider }) {
                selectedProvider = defaultProvider
            } else {
                selectedProvider = availableModelProviders[0].id
            }
        }
        let providerModels = models(for: selectedProvider)
        let modelIds = Set(providerModels.map(\.id))
        if selectedModel.isEmpty || !modelIds.contains(selectedModel) {
            isApplyingRemoteSettings = true
            defer { isApplyingRemoteSettings = false }
            selectedModel = availableModelProviders.first(where: { $0.id == selectedProvider })?.defaultModel ?? providerModels.first?.id ?? defaultModel
        }
    }

    func models(for providerId: String) -> [AvailableModel] {
        availableModelProviders.first(where: { $0.id == providerId })?.models ?? []
    }

    func fetchVoices() async {
        guard let c = client else { return }
        if let resp = try? await c.listVoices() {
            applyVoices(resp)
        }
    }

    func fetchTools() async {
        guard let c = client else { return }
        guard let tools = try? await c.listTools() else { return }
        availableTools = tools
        // The universal selection lives on the server (config.yaml); seed the
        // local toggles from what the server reports as enabled.
        enabledTools = Set(tools.filter(\.enabled).map(\.name))
    }

    /// Persist the universal toolset selection to the server. Takes effect on
    /// the next run (the gateway re-reads config per run).
    func saveToolsets() async -> Bool {
        guard let c = client else { return false }
        do {
            try await c.saveTools(enabled: Array(enabledTools))
            return true
        } catch {
            return false
        }
    }

    private func applyRemote(_ s: UISettings) {
        isApplyingRemoteSettings = true
        defer { isApplyingRemoteSettings = false }
        if !s.systemPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || systemPrompt.isEmpty {
            systemPrompt = s.systemPrompt
        }
        contextLimit = s.contextLimit
        if !s.selectedProvider.isEmpty { selectedProvider = s.selectedProvider }
        if !s.selectedModel.isEmpty { selectedModel = s.selectedModel }
        ttsVoice = s.ttsVoice
        autoSpeak = true
        vadSilenceMs = s.vadSilenceMs
        fontSize = s.fontSize
        messageDensity = s.messageDensity
        backgroundNotifications = s.backgroundNotifications
    }

    private func applyChannelCapabilities(_ caps: ChannelCapabilities) {
        channelCapabilities = caps
        if !caps.brain.models.isEmpty {
            availableModels = caps.brain.models
            availableModelProviders = caps.brain.providers ?? availableModelProviders
            normalizeModelSelection(defaultProvider: caps.brain.defaultProvider ?? "", defaultModel: caps.brain.defaultModel)
        }
        if let voices = caps.voice.voices {
            availableHermesVoices = voices
        }
        defaultHermesVoice = caps.voice.defaultVoice ?? defaultHermesVoice
        normalizeHermesVoiceSelection()
        if shouldAdoptChannelVoiceDefault {
            ttsEngine = caps.voice.hermesTtsAvailable ? .server : .apple
            shouldAdoptChannelVoiceDefault = false
        } else if ttsEngine == .server, !caps.voice.hermesTtsAvailable {
            ttsEngine = .apple
        }
    }

    private func applyVoices(_ response: VoicesResponse) {
        availableHermesVoices = response.voices
        defaultHermesVoice = response.default
        normalizeHermesVoiceSelection()
        if ttsEngine == .server, !hermesTtsAvailable {
            ttsEngine = .apple
        }
    }

    private func normalizeHermesVoiceSelection() {
        guard !availableHermesVoices.isEmpty else { return }
        let supportedIds = Set(availableHermesVoices.filter(\.supported).map(\.id))
        if !ttsVoice.isEmpty && !supportedIds.contains(ttsVoice) {
            ttsVoice = ""
        }
    }

    private func rebuildClient() {
        guard !serverURL.isEmpty, let url = URL(string: serverURL) else {
            client = nil
            TimingReporter.disable()
            return
        }
        client = HermesClient(baseURL: url, apiKey: apiKey)
        TimingReporter.configure(baseURL: url, apiKey: apiKey)
    }

    private func scheduleSyncToServerIfNeeded() {
        guard !isApplyingRemoteSettings else { return }
        syncTask?.cancel()
        syncTask = Task { [weak self] in
            guard let self else { return }
            try? await Task.sleep(for: .milliseconds(600))
            guard !Task.isCancelled else { return }
            await self.pushToServer()
        }
    }

    private func pushToServer() async {
        guard let c = client else { return }
        let snapshot = UISettings(
            systemPrompt: systemPrompt,
            contextLimit: contextLimit,
            selectedProvider: selectedProvider,
            selectedModel: selectedModel,
            ttsVoice: ttsVoice,
            autoSpeak: true,
            vadSilenceMs: vadSilenceMs,
            fontSize: fontSize,
            messageDensity: messageDensity,
            backgroundNotifications: backgroundNotifications
        )
        try? await c.saveSettings(snapshot)
    }
}
