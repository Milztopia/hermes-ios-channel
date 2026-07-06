import SwiftUI
import Highlightr

// MARK: - HighlightedCodeView

struct HighlightedCodeView: View {
    let code: String
    let language: String?
    @Environment(\.colorScheme) private var colorScheme
    @State private var attributed: NSAttributedString?

    private var bgColor: Color {
        colorScheme == .dark ? Color(red: 0.16, green: 0.17, blue: 0.21) : Color(red: 0.97, green: 0.97, blue: 0.97)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Language label + copy button
            HStack {
                if let lang = language, !lang.isEmpty {
                    Text(lang.lowercased())
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                CopyButton(text: code)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(colorScheme == .dark ? Color.black.opacity(0.3) : Color.black.opacity(0.06))

            // Code content
            ScrollView(.horizontal, showsIndicators: false) {
                Group {
                    if let attr = attributed {
                        AttributedTextView(attributedString: attr)
                            .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
                    } else {
                        Text(code)
                            .font(.system(.caption, design: .monospaced))
                            .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(12)
            }
        }
        .background(bgColor)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .task(id: code + (language ?? "") + "\(colorScheme == .dark)") {
            attributed = highlight(code: code, language: language, dark: colorScheme == .dark)
        }
    }

    private func highlight(code: String, language: String?, dark: Bool) -> NSAttributedString? {
        guard let highlightr = Highlightr() else { return nil }
        highlightr.setTheme(to: dark ? "atom-one-dark" : "xcode")
        let lang = language?.lowercased().trimmingCharacters(in: .whitespaces)
        if let lang, !lang.isEmpty, let result = highlightr.highlight(code, as: lang) {
            return result
        }
        return highlightr.highlight(code, as: "plaintext")
    }
}

// MARK: - AttributedTextView (UITextView wrapper for NSAttributedString)

struct AttributedTextView: UIViewRepresentable {
    let attributedString: NSAttributedString

    func makeUIView(context: Context) -> UITextView {
        let tv = UITextView()
        tv.isEditable = false
        tv.isScrollEnabled = false
        tv.backgroundColor = .clear
        tv.textContainerInset = .zero
        tv.textContainer.lineFragmentPadding = 0
        tv.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        tv.setContentHuggingPriority(.defaultHigh, for: .vertical)
        return tv
    }

    func updateUIView(_ tv: UITextView, context: Context) {
        tv.attributedText = attributedString
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: UITextView, context: Context) -> CGSize? {
        let w = proposal.width ?? UIScreen.main.bounds.width
        let size = uiView.sizeThatFits(CGSize(width: w, height: .greatestFiniteMagnitude))
        return size
    }
}

// MARK: - CopyButton

struct CopyButton: View {
    let text: String
    @State private var copied = false

    var body: some View {
        Button {
            UIPasteboard.general.string = text
            copied = true
            Task {
                try? await Task.sleep(for: .seconds(2))
                copied = false
            }
        } label: {
            Image(systemName: copied ? "checkmark" : "doc.on.doc")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
    }
}
