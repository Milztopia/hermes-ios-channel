import SwiftUI
import MarkdownUI

// MARK: - TappableImageProvider
// Custom MarkdownUI image provider that makes all inline images tappable,
// opening the ImageLightboxView. Handles both http(s) and data: URLs.

struct TappableImageProvider: ImageProvider {
    var baseURL: URL? = nil
    var apiKey: String? = nil
    func makeImage(url: URL?) -> some View {
        InlineImageView(url: url, baseURL: baseURL, apiKey: apiKey)
    }
}

// MARK: - InlineImageView

private struct InlineImageView: View {
    let url: URL?
    var baseURL: URL? = nil
    var apiKey: String? = nil
    @State private var uiImage: UIImage?
    @State private var failed = false
    @State private var showLightbox = false

    // Resolve relative/host-less URLs (e.g. /api/hermes-img/..., /api/img/...)
    // against the configured server so the device can actually fetch them.
    private var resolvedURL: URL? {
        guard let url else { return nil }
        if url.scheme != nil { return url }            // http(s)/data/file — use as-is
        if let baseURL { return URL(string: url.absoluteString, relativeTo: baseURL)?.absoluteURL }
        return url
    }

    var body: some View {
        Group {
            if let img = uiImage {
                Image(uiImage: img)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: 320)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                    .onTapGesture {
                        Haptics.impact(.light)
                        showLightbox = true
                    }
                    .fullScreenCover(isPresented: $showLightbox) {
                        ImageLightboxView(image: img) { showLightbox = false }
                    }
            } else if failed {
                Label("Image unavailable", systemImage: "photo")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(8)
            } else {
                RoundedRectangle(cornerRadius: 10)
                    .fill(Color(.systemGray6))
                    .frame(width: 240, height: 160)
                    .overlay { ProgressView() }
            }
        }
        .task(id: url?.absoluteString) { await load() }
    }

    private func load() async {
        guard let url = resolvedURL else { failed = true; return }
        let str = url.absoluteString

        if str.hasPrefix("data:") {
            // data: URL — decode base64 inline
            guard let commaIdx = str.firstIndex(of: ",") else { failed = true; return }
            let b64 = String(str[str.index(after: commaIdx)...])
            if let data = Data(base64Encoded: b64, options: .ignoreUnknownCharacters),
               let img = UIImage(data: data) {
                uiImage = img
            } else {
                failed = true
            }
        } else {
            // http/https URL — fetch with URLSession, attaching the bearer token.
            // Image endpoints (/api/hermes-img/..., /api/img/...) sit behind the
            // same auth as the rest of the API; a bare data(from:) sends no header
            // and gets 401, which rendered as "Image unavailable".
            do {
                var req = URLRequest(url: url)
                if let token = apiKey?.trimmingCharacters(in: .whitespacesAndNewlines), !token.isEmpty {
                    req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
                }
                let (data, _) = try await URLSession.shared.data(for: req)
                if let img = UIImage(data: data) {
                    uiImage = img
                } else {
                    failed = true
                }
            } catch {
                failed = true
            }
        }
    }
}
