import Foundation

// Fire-and-forget timing reporter: POSTs labeled timestamps to /api/debug/timing
// so the server log captures the full iOS pipeline latency without needing Xcode attached.
// Disabled automatically when no base URL is configured.

enum TimingReporter {
    private static var baseURL: URL?
    private static var apiKey: String = ""
    private static var t0: Date = Date()

    static func configure(baseURL: URL, apiKey: String) {
        Self.baseURL = baseURL
        Self.apiKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        Self.t0 = Date()
    }

    static func disable() {
        Self.baseURL = nil
        Self.apiKey = ""
    }

    static func reset() {
        Self.t0 = Date()
    }

    static func mark(_ label: String, detail: String = "") {
        guard let base = baseURL else { return }
        let elapsed = Date().timeIntervalSince(t0)
        let url = base.appendingPathComponent("api/debug/timing")
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if !apiKey.isEmpty {
            req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }
        let body: [String: Any] = ["label": label, "elapsed": elapsed, "detail": detail]
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        URLSession.shared.dataTask(with: req).resume()
    }
}
