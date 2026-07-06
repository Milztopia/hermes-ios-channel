import SwiftUI
import AVFoundation

struct SettingsView: View {
    @Environment(SettingsStore.self) private var settings
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                // Connection
                Section {
                    NavigationLink {
                        ConnectionTab().environment(settings)
                    } label: {
                        Label("Connection", systemImage: "network")
                    }
                }

                // AI Model
                Section {
                    NavigationLink {
                        ModelTab().environment(settings)
                    } label: {
                        Label("AI Model", systemImage: "cpu")
                    }
                }

                // Voice
                Section {
                    NavigationLink {
                        VoiceTab().environment(settings)
                    } label: {
                        Label("Voice", systemImage: "waveform")
                    }
                }

                // Appearance
                Section {
                    NavigationLink {
                        AppearanceTab().environment(settings)
                    } label: {
                        Label("Appearance", systemImage: "paintpalette")
                    }
                }

                // Tools
                Section {
                    NavigationLink {
                        ToolsTab().environment(settings)
                    } label: {
                        Label("Tools", systemImage: "wrench.and.screwdriver")
                    }
                }

                Section(footer: Text("Hermes Mobile")) {
                    HStack {
                        Label("Status", systemImage: "circle.fill")
                            .symbolRenderingMode(.hierarchical)
                        Spacer()
                        connectionStatusLabel
                    }
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    private var connectionStatusLabel: some View {
        switch settings.connectionState {
        case .connected:
            return Text("Connected").foregroundStyle(.green)
        case .failed(let msg):
            return Text("Error: \(msg)").foregroundStyle(.red)
        case .unknown:
            return Text("Not verified").foregroundStyle(.secondary)
        }
    }
}

// MARK: - ConnectionTab

struct ConnectionTab: View {
    @Environment(SettingsStore.self) private var settings
    @State private var serverURL = ""
    @State private var apiKey = ""
    @State private var testing = false
    @State private var testResult: String?

    var body: some View {
        Form {
            Section {
                TextField("https://your-server:3001", text: $serverURL)
                    .keyboardType(.URL)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
            } header: {
                Text("Server URL")
            } footer: {
                Text("Local IP, VPN address, or HTTPS domain. Include the port (default 3001).")
            }

            Section {
                SecureField("API Key (optional)", text: $apiKey)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
            } header: {
                Text("API Key")
            } footer: {
                Text("Set if your server requires Authorization: Bearer authentication.")
            }

            Section {
                Button {
                    Task { await testConnection() }
                } label: {
                    HStack {
                        Text(testing ? "Testing…" : "Test Connection")
                        Spacer()
                        if testing { ProgressView() }
                    }
                }
                .disabled(serverURL.isEmpty || testing)

                if let result = testResult {
                    Text(result)
                        .font(.caption)
                        .foregroundStyle(result.hasPrefix("✓") ? .green : .red)
                }
            }
        }
        .navigationTitle("Connection")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            serverURL = settings.serverURL
            apiKey = settings.apiKey
        }
        .onChange(of: serverURL) { _, v in settings.serverURL = v }
        .onChange(of: apiKey) { _, v in settings.apiKey = v }
    }

    private func testConnection() async {
        testing = true
        testResult = nil
        let ok = await settings.testConnection()
        testResult = ok ? "✓ Connected successfully" : "✗ \(errorMessage)"
        testing = false
    }

    private var errorMessage: String {
        if case .failed(let msg) = settings.connectionState { return msg }
        return "Connection failed"
    }
}

// MARK: - ModelTab

struct ModelTab: View {
    @Environment(SettingsStore.self) private var settings
    @State private var localPrompt = ""
    @State private var localLimit = ""

    var body: some View {
        Form {
            Section("Model") {
                if settings.availableModelProviders.isEmpty {
                    Text("No models available").foregroundStyle(.secondary)
                } else {
                    @Bindable var s = settings
                    Picker("Provider", selection: $s.selectedProvider) {
                        ForEach(settings.availableModelProviders) { provider in
                            Text(provider.name).tag(provider.id)
                        }
                    }
                    Picker("Model", selection: $s.selectedModel) {
                        ForEach(settings.models(for: settings.selectedProvider)) { model in
                            Text(model.name).tag(model.id)
                        }
                    }
                }
            }

            Section("System Prompt") {
                @Bindable var s = settings
                TextEditor(text: $s.systemPrompt)
                    .frame(minHeight: 120)
                    .font(.body)
            }

            Section {
                @Bindable var s = settings
                Stepper("Context limit: \(s.contextLimit == 0 ? "Unlimited" : "\(s.contextLimit) messages")",
                        value: $s.contextLimit, in: 0...100, step: 5)
            } header: {
                Text("Context Limit")
            } footer: {
                Text("0 = send full conversation history.")
            }
        }
        .navigationTitle("AI Model")
        .navigationBarTitleDisplayMode(.inline)
        .task { await settings.fetchModels() }
        .onChange(of: settings.selectedProvider) { _, provider in
            let models = settings.models(for: provider)
            if !models.contains(where: { $0.id == settings.selectedModel }) {
                settings.selectedModel = models.first?.id ?? ""
            }
        }
    }
}

// MARK: - VoiceTab

struct VoiceTab: View {
    @Environment(SettingsStore.self) private var settings

    var body: some View {
        Form {
            Section("TTS Engine") {
                @Bindable var s = settings
                Picker("Engine", selection: $s.ttsEngine) {
                    Text("Hermes").tag(SettingsStore.TTSEngine.server)
                        .disabled(!settings.hermesTtsAvailable)
                    Text("On-Device (Apple)").tag(SettingsStore.TTSEngine.apple)
                    Text("On-Device (Kokoro)").tag(SettingsStore.TTSEngine.kokoro)
                }
                .pickerStyle(.inline)
                .labelsHidden()
            }

            if settings.ttsEngine == .server {
                Section("Hermes Voice") {
                    @Bindable var s = settings
                    if settings.availableHermesVoices.isEmpty {
                        Text("Uses the default TTS voice configured in Hermes.")
                            .foregroundStyle(.secondary)
                    } else {
                        Picker("Voice", selection: $s.ttsVoice) {
                            Text("Default (Hermes)").tag("")
                            ForEach(settings.availableHermesVoices) { voice in
                                Text(voice.name).tag(voice.id)
                                    .disabled(!voice.supported)
                            }
                        }
                        if let selected = settings.availableHermesVoices.first(where: { $0.id == settings.ttsVoice }),
                           !selected.supported,
                           let reason = selected.reason {
                            Text(reason).foregroundStyle(.secondary)
                        }
                        if settings.availableHermesVoices.allSatisfy({ !$0.id.contains(":") }) {
                            Text("Hermes is exposing provider defaults only. Provider-specific voices require that provider to publish a voice list.")
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            } else if !settings.hermesTtsAvailable {
                Section("Hermes Voice") {
                    Text("Hermes is not reporting a supported TTS provider, so voice mode uses on-device speech.")
                        .foregroundStyle(.secondary)
                }
            }

            if settings.ttsEngine == .apple {
                OnDeviceVoicePickerSection()
            }

            if settings.ttsEngine == .kokoro {
                KokoroVoicePickerSection()
            }

            Section("STT Engine") {
                @Bindable var s = settings
                Picker("Engine", selection: $s.sttEngine) {
                    Text("On-Device (WhisperKit)").tag(SettingsStore.STTEngine.onDevice)
                    Text("Server (Whisper)").tag(SettingsStore.STTEngine.server)
                }
                .pickerStyle(.inline)
                .labelsHidden()
            }

            Section {
                @Bindable var s = settings
                Toggle("Barge-in by Default", isOn: $s.defaultBargeInEnabled)
                LabeledContent("Silence Threshold") {
                    HStack {
                        Slider(value: Binding(
                            get: { Double(s.vadSilenceMs) },
                            set: { s.vadSilenceMs = Int($0) }
                        ), in: 500...3000, step: 100)
                        Text("\(s.vadSilenceMs)ms")
                            .font(.caption)
                            .frame(width: 54, alignment: .trailing)
                    }
                }
            } header: {
                Text("Voice Mode")
            } footer: {
                Text("New chats begin with this barge-in setting. Changing the toggle inside voice mode is remembered only for that chat.")
            }
        }
        .navigationTitle("Voice")
        .navigationBarTitleDisplayMode(.inline)
        .task { await settings.fetchVoices() }
    }

    static let kokoroVoices  = ["af_heart", "af_bella", "am_adam", "bf_emma",
                                 "bm_george", "bm_lewis", "af_nicole"]
}

// MARK: - On-device Kokoro neural voice picker

private struct KokoroVoicePickerSection: View {
    @Environment(SettingsStore.self) private var settings
    @State private var kokoro = KokoroService.shared
    @State private var tts = TTSService()
    @State private var previewing: String?

    var body: some View {
        Section {
            @Bindable var s = settings
            ForEach(KokoroService.allVoices, id: \.self) { v in
                HStack(spacing: 12) {
                    Image(systemName: s.kokoroVoice == v ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(s.kokoroVoice == v ? Color.accentColor : .secondary)
                        .font(.system(size: 18))
                        .onTapGesture { s.kokoroVoice = v }

                    VStack(alignment: .leading, spacing: 1) {
                        Text(prettyName(v)).font(.body)
                        Text(regionGender(v)).font(.caption2).foregroundStyle(.secondary)
                    }
                    .contentShape(Rectangle())
                    .onTapGesture { s.kokoroVoice = v }

                    Spacer()

                    Button { Task { await preview(v) } } label: {
                        if previewing == v {
                            ProgressView()
                        } else {
                            Image(systemName: "play.circle").font(.system(size: 22)).foregroundStyle(Color.accentColor)
                        }
                    }
                    .buttonStyle(.plain)
                    .disabled(previewing != nil || kokoro.isLoading)
                }
                .padding(.vertical, 2)
            }
        } header: {
            Text("Kokoro Voice")
        } footer: {
            if let e = kokoro.loadError {
                Text("Kokoro error: \(e)").foregroundStyle(.red)
            } else {
                Text("On-device neural voices — fully offline. First use loads a ~327 MB model (a few seconds); after that it's instant.")
            }
        }
    }

    private func preview(_ v: String) async {
        previewing = v
        defer { previewing = nil }
        if let samples = await kokoro.synthesize(text: "Hello, I'm the \(prettyName(v)) voice.", voice: v) {
            await tts.play(samples: samples, sampleRate: 24000)
        }
    }

    private func prettyName(_ v: String) -> String {
        v.split(separator: "_").dropFirst().joined(separator: " ").capitalized
    }

    private func regionGender(_ v: String) -> String {
        switch v.prefix(2) {
        case "af": return "US · Female"
        case "am": return "US · Male"
        case "bf": return "UK · Female"
        case "bm": return "UK · Male"
        default:   return ""
        }
    }
}

// MARK: - On-device voice picker (AVSpeechSynthesizer)

private struct OnDeviceVoicePickerSection: View {
    @Environment(SettingsStore.self) private var settings
    @State private var synth = AVSpeechSynthesizer()
    @State private var previewingId: String?

    private var voices: [AVSpeechSynthesisVoice] {
        AVSpeechSynthesisVoice.speechVoices()
            .filter { $0.language.hasPrefix("en") }
            .sorted { a, b in
                a.quality.rawValue != b.quality.rawValue
                    ? a.quality.rawValue > b.quality.rawValue
                    : a.name < b.name
            }
    }

    var body: some View {
        Section {
            if voices.isEmpty {
                Text("No English voices found. Add voices in Settings → Accessibility → Spoken Content → Voices.")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                @Bindable var s = settings
                ForEach(voices, id: \.identifier) { v in
                    HStack(spacing: 12) {
                        Image(systemName: s.onDeviceVoiceId == v.identifier ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(s.onDeviceVoiceId == v.identifier ? Color.accentColor : .secondary)
                            .font(.system(size: 18))
                            .onTapGesture { s.onDeviceVoiceId = v.identifier }

                        VStack(alignment: .leading, spacing: 1) {
                            Text(v.name).font(.body)
                            Text("\(qualityLabel(v.quality)) · \(v.language)")
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                        .contentShape(Rectangle())
                        .onTapGesture { s.onDeviceVoiceId = v.identifier }

                        Spacer()

                        Button { preview(v) } label: {
                            Image(systemName: previewingId == v.identifier ? "stop.circle" : "play.circle")
                                .font(.system(size: 22))
                                .foregroundStyle(Color.accentColor)
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.vertical, 2)
                }
            }
        } header: {
            Text("On-Device Voice")
        } footer: {
            Text("Fully on-device — no server needed. Download higher-quality Premium/Enhanced voices in iOS Settings → Accessibility → Spoken Content → Voices.")
        }
    }

    private func preview(_ v: AVSpeechSynthesisVoice) {
        if synth.isSpeaking { synth.stopSpeaking(at: .immediate) }
        try? AVAudioSession.sharedInstance().setCategory(.playback, options: [.duckOthers])
        try? AVAudioSession.sharedInstance().setActive(true)
        let u = AVSpeechUtterance(string: "Hello, I'm \(v.name). This is how I sound.")
        u.voice = v
        previewingId = v.identifier
        synth.speak(u)
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) {
            if previewingId == v.identifier { previewingId = nil }
        }
    }

    private func qualityLabel(_ q: AVSpeechSynthesisVoiceQuality) -> String {
        switch q {
        case .premium:  return "Premium"
        case .enhanced: return "Enhanced"
        default:        return "Default"
        }
    }
}

// MARK: - AppearanceTab

struct AppearanceTab: View {
    @Environment(SettingsStore.self) private var settings

    var body: some View {
        Form {
            Section("Font Size") {
                @Bindable var s = settings
                Picker("Font Size", selection: $s.fontSize) {
                    Text("Small").tag("small")
                    Text("Medium").tag("medium")
                    Text("Large").tag("large")
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }

            Section("Message Density") {
                @Bindable var s = settings
                Picker("Density", selection: $s.messageDensity) {
                    Text("Compact").tag("compact")
                    Text("Comfortable").tag("comfortable")
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }
        }
        .navigationTitle("Appearance")
        .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: - ToolsTab

struct ToolsTab: View {
    @Environment(SettingsStore.self) private var settings
    @State private var saving = false
    @State private var loaded = false

    var body: some View {
        Form {
            if settings.availableTools.isEmpty {
                Section {
                    VStack(spacing: 12) {
                        Image(systemName: "wrench.and.screwdriver")
                            .font(.largeTitle)
                            .foregroundStyle(.secondary)
                        Text(loaded ? "No toolsets available" : "Loading toolsets…")
                            .font(.headline)
                        Text("Connect to your Hermes server to load available toolsets.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 16)
                }
            } else {
                Section {
                    @Bindable var s = settings
                    ForEach(settings.availableTools) { tool in
                        ToolRow(
                            tool: tool,
                            isEnabled: Binding(
                                get: { s.enabledTools.contains(tool.name) },
                                set: { on in
                                    if on { s.enabledTools.insert(tool.name) }
                                    else  { s.enabledTools.remove(tool.name) }
                                }
                            )
                        )
                        .disabled(!tool.available)
                    }
                } header: {
                    Text("Toolsets")
                } footer: {
                    Text("Enabled toolsets load into the model's context on every message. Fewer toolsets means faster, cheaper runs. Tap Save to apply to all chats (takes effect on the next message).")
                }
            }
        }
        .navigationTitle("Tools")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button {
                    Task {
                        saving = true
                        let ok = await settings.saveToolsets()
                        saving = false
                        Haptics.notification(ok ? .success : .error)
                    }
                } label: {
                    if saving { ProgressView() } else { Text("Save") }
                }
                .disabled(saving || settings.availableTools.isEmpty)
            }
        }
        .task {
            await settings.fetchTools()
            loaded = true
        }
    }
}

private struct ToolRow: View {
    let tool: HermesToolDefinition
    @Binding var isEnabled: Bool

    var body: some View {
        Toggle(isOn: $isEnabled) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(tool.label ?? tool.name)
                        .font(.body)
                    if !tool.available {
                        Text("unavailable")
                            .font(.caption2)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(Color.secondary.opacity(0.15))
                            .foregroundStyle(.secondary)
                            .clipShape(Capsule())
                    }
                }
                if !tool.tools.isEmpty {
                    Text(tool.tools.joined(separator: ", "))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                } else if !tool.available, !tool.requirements.isEmpty {
                    Text("Requires \(tool.requirements.joined(separator: ", "))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                } else if let desc = tool.description, !desc.isEmpty {
                    Text(desc)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if !tool.available, !tool.requirements.isEmpty, !tool.tools.isEmpty {
                    Text("Requires \(tool.requirements.joined(separator: ", "))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
        }
    }
}
