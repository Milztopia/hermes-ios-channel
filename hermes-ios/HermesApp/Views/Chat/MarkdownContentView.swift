import SwiftUI
import MarkdownUI

// MARK: - Markdown segment types

private enum MarkdownPart {
    case text(String)
    case code(language: String, code: String)
}

// MARK: - MarkdownContentView
// Splits message content into prose segments and fenced code blocks,
// rendering prose with MarkdownUI and code blocks with Highlightr.

struct MarkdownContentView: View, Equatable {
    let content: String
    /// Server base URL, used to resolve relative/agent-local image references.
    var baseURL: URL? = nil
    /// Bearer token for fetching auth-gated images (e.g. /api/hermes-img/...).
    var apiKey: String? = nil

    // Equatable so a stable streaming prefix whose text hasn't changed is skipped
    // by SwiftUI (via `.equatable()`) instead of re-parsing Markdown every token.
    static func == (lhs: MarkdownContentView, rhs: MarkdownContentView) -> Bool {
        lhs.content == rhs.content && lhs.baseURL == rhs.baseURL && lhs.apiKey == rhs.apiKey
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(parts.enumerated()), id: \.offset) { _, part in
                switch part {
                case .text(let text):
                    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !trimmed.isEmpty {
                        Markdown(trimmed)
                            // Keep gitHub typography but drop its filled background
                            // box behind body text (gitHub sets BackgroundColor on
                            // .text) — just plain text on the chat background.
                            .markdownTheme(.gitHub.text {
                                ForegroundColor(.primary)
                                FontSize(16)
                            })
                            .markdownImageProvider(TappableImageProvider(baseURL: baseURL, apiKey: apiKey))
                            .textSelection(.enabled)
                    }
                case .code(let lang, let code):
                    HighlightedCodeView(code: code, language: lang.isEmpty ? nil : lang)
                }
            }
        }
    }

    private var parts: [MarkdownPart] {
        splitMarkdown(rewriteLocalImagePaths(content))
    }
}

// Rewrite agent-emitted local filesystem image paths (e.g. /home/.../foo.png or
// file:///...) to the server's /api/hermes-img/<filename> route, mirroring the
// web app. The provider then resolves that relative path against the base URL.
private func rewriteLocalImagePaths(_ text: String) -> String {
    rewriteStandaloneLocalImagePaths(rewriteMarkdownLocalImageLinks(text))
}

private func rewriteMarkdownLocalImageLinks(_ text: String) -> String {
    guard text.contains("](") else { return text }
    let pattern = #"!\[([^\]]*)\]\(((?:file://)?(?:/home/|/root/|/Users/)[^)]*?\.(?:jpg|jpeg|png|webp|gif))\)"#
    guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return text }
    let mutable = NSMutableString(string: text)
    let matches = re.matches(in: text, range: NSRange(location: 0, length: (text as NSString).length))
    for m in matches.reversed() {
        let alt = (text as NSString).substring(with: m.range(at: 1))
        let url = (text as NSString).substring(with: m.range(at: 2))
        mutable.replaceCharacters(in: m.range, with: "![\(alt)](\(hermesImageRoute(for: url)))")
    }
    return mutable as String
}

private func rewriteStandaloneLocalImagePaths(_ text: String) -> String {
    let pattern = #"(?m)(^|[ \t\n])((?:file://)?(?:/home/|/root/|/Users/)[^\s\])]+?\.(?:jpg|jpeg|png|webp|gif))(?=$|[ \t\n])"#
    guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return text }
    let nsText = text as NSString
    let mutable = NSMutableString(string: text)
    let matches = re.matches(in: text, range: NSRange(location: 0, length: nsText.length))
    for m in matches.reversed() {
        let prefix = nsText.substring(with: m.range(at: 1))
        let url = nsText.substring(with: m.range(at: 2))
        mutable.replaceCharacters(in: m.range, with: "\(prefix)![](\(hermesImageRoute(for: url)))")
    }
    return mutable as String
}

private func hermesImageRoute(for localPath: String) -> String {
    let filename = (localPath as NSString).lastPathComponent
    let encoded = filename.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? filename
    return "/api/hermes-img/\(encoded)"
}

// MARK: - Parser

private func splitMarkdown(_ markdown: String) -> [MarkdownPart] {
    guard markdown.contains("```") else { return [.text(markdown)] }

    var parts: [MarkdownPart] = []
    var remaining = markdown

    while !remaining.isEmpty {
        // Find next fenced code block
        guard let fenceStart = remaining.range(of: "```") else {
            parts.append(.text(remaining))
            break
        }

        // Text before the fence
        let textBefore = String(remaining[remaining.startIndex..<fenceStart.lowerBound])
        if !textBefore.isEmpty { parts.append(.text(textBefore)) }

        // After opening ```
        let afterFence = remaining[fenceStart.upperBound...]

        // Extract optional language identifier (up to newline)
        let langEnd = afterFence.firstIndex(of: "\n") ?? afterFence.endIndex
        let lang = String(afterFence[afterFence.startIndex..<langEnd])
            .trimmingCharacters(in: .whitespacesAndNewlines)

        let codeStart = langEnd < afterFence.endIndex
            ? afterFence.index(after: langEnd) : afterFence.endIndex
        let codeContent = String(afterFence[codeStart...])

        // Find closing ```
        if let closeRange = codeContent.range(of: "```") {
            let code = String(codeContent[codeContent.startIndex..<closeRange.lowerBound])
            parts.append(.code(language: lang, code: code))
            // Move past the closing fence
            let afterClose = codeContent[closeRange.upperBound...]
            remaining = String(afterClose)
        } else {
            // Unclosed fence — treat the rest as code
            parts.append(.code(language: lang, code: codeContent))
            break
        }
    }

    return parts.isEmpty ? [.text(markdown)] : parts
}

// MARK: - StreamingMarkdownView
// Live Markdown while a reply streams, without the O(n²) hang of re-parsing the
// whole growing message every token. Splits the text into a STABLE prefix
// (completed blocks) and an ACTIVE tail (the block still being written):
//  • the prefix is parsed as one Markdown document (correct list numbering,
//    blockquotes, etc.) and, being `.equatable()`, only re-parses when a new block
//    boundary is crossed — not every token;
//  • the active tail is just the current block, so re-parsing it per token is cheap.
// Pair with the ~20 Hz delta coalescing in ChatStore.streamRun.

struct StreamingMarkdownView: View {
    let content: String
    var baseURL: URL? = nil
    var apiKey: String? = nil

    var body: some View {
        let split = splitStreamingMarkdown(content)
        VStack(alignment: .leading, spacing: 8) {
            if !split.stable.isEmpty {
                MarkdownContentView(content: split.stable, baseURL: baseURL, apiKey: apiKey)
                    .equatable()
            }
            if !split.active.isEmpty {
                MarkdownContentView(content: split.active, baseURL: baseURL, apiKey: apiKey)
            }
        }
    }
}

/// Split streamed markdown into a stable prefix (everything up to the last blank-line
/// block boundary that sits OUTSIDE a code fence) and the active tail (the block
/// still being written, including any open ``` fence). Returns ("", text) when no
/// safe boundary exists yet.
func splitStreamingMarkdown(_ text: String) -> (stable: String, active: String) {
    let chars = Array(text)
    var inFence = false
    var lastBoundary = 0          // char offset where the active tail starts
    var i = 0
    while i < chars.count {
        // Triple-backtick toggles fenced-code state (inline code uses single ticks).
        if chars[i] == "`", i + 2 < chars.count, chars[i + 1] == "`", chars[i + 2] == "`" {
            inFence.toggle()
            i += 3
            continue
        }
        // A blank line outside a fence ends a block — safe to freeze up to here.
        if !inFence, chars[i] == "\n", i + 1 < chars.count, chars[i + 1] == "\n" {
            lastBoundary = i + 2
            i += 2
            continue
        }
        i += 1
    }
    guard lastBoundary > 0, lastBoundary < chars.count else { return ("", text) }
    let splitIdx = text.index(text.startIndex, offsetBy: lastBoundary)
    return (String(text[..<splitIdx]), String(text[splitIdx...]))
}
