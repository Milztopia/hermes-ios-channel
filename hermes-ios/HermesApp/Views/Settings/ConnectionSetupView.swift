import SwiftUI

struct ConnectionSetupView: View {
    @Environment(SettingsStore.self) private var settings
    @State private var serverURL = ""
    @State private var apiKey = ""
    @State private var testing = false
    @State private var errorMessage: String?

    var body: some View {
        VStack(spacing: 0) {
            Spacer()

            VStack(spacing: 24) {
                VStack(spacing: 8) {
                    Image(systemName: "sparkles")
                        .font(.system(size: 56))
                        .foregroundStyle(.tint)
                    Text("Welcome to Hermes")
                        .font(.title).bold()
                    Text("Enter your server address to get started.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }

                VStack(spacing: 12) {
                    TextField("Server URL  (e.g. http://100.94.x.x:3001)", text: $serverURL)
                        .keyboardType(.URL)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .padding()
                        .background(Color(.systemGray6))
                        .clipShape(RoundedRectangle(cornerRadius: 12))

                    SecureField("API Key (optional)", text: $apiKey)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .padding()
                        .background(Color(.systemGray6))
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                }

                if let err = errorMessage {
                    Text(err)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .multilineTextAlignment(.center)
                }

                Button {
                    Task { await connect() }
                } label: {
                    HStack {
                        if testing { ProgressView().tint(.white) }
                        Text(testing ? "Connecting…" : "Connect")
                    }
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(serverURL.isEmpty ? Color.secondary : Color.accentColor)
                    .foregroundStyle(.white)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                }
                .disabled(serverURL.isEmpty || testing)
            }
            .padding(.horizontal, 32)

            Spacer()

            Text("Your server URL should be reachable from this device — local Wi-Fi IP, VPN address, or HTTPS domain.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
                .padding(.bottom, 32)
        }
    }

    private func connect() async {
        testing = true
        errorMessage = nil
        let trimmedURL = serverURL.trimmingCharacters(in: .whitespacesAndNewlines)
        // Test without setting settings.serverURL first — avoids RootView switching away
        // and destroying this view's @State before the error can be shown
        let ok = await settings.testConnection(serverURL: trimmedURL, apiKey: apiKey)
        if ok {
            settings.serverURL = trimmedURL
            settings.apiKey = apiKey
            await settings.loadFromServer()
            await settings.fetchModels()
        } else {
            if case .failed(let msg) = settings.connectionState {
                errorMessage = msg
            } else {
                errorMessage = "Could not connect. Check the URL and try again."
            }
        }
        testing = false
    }
}
