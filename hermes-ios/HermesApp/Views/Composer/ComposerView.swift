import SwiftUI
import PhotosUI
import UniformTypeIdentifiers

struct ComposerView: View {
    @Environment(SettingsStore.self) private var settings
    @Environment(ChatStore.self) private var chatStore
    @Environment(VoiceCoordinator.self) private var voice
    let chatId: String

    @State private var text = ""
    @State private var attachments: [ChatAttachment] = []
    @State private var photoItem: PhotosPickerItem?
    @State private var showPhotoPicker = false
    @State private var showDocPicker = false
    @State private var showCamera = false
    @State private var isProcessingAttachment = false
    @State private var showVoiceMode = false
    @FocusState private var textFocused: Bool

    private var isStreaming: Bool { chatStore.isStreaming[chatId] == true }
    private var hasContent: Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !attachments.isEmpty
    }

    var body: some View {
        VStack(spacing: 0) {
            // Attachment strip
            if !attachments.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(Array(attachments.enumerated()), id: \.offset) { idx, att in
                            attachmentChip(att, index: idx)
                        }
                    }
                    .padding(.horizontal, 16).padding(.vertical, 8)
                }
                Divider()
            }

            HStack(alignment: .center, spacing: 10) {
                // Attachment menu (+): photos, camera, files
                Menu {
                    Button { showPhotoPicker = true } label: {
                        Label("Photos", systemImage: "photo")
                    }
                    if UIImagePickerController.isSourceTypeAvailable(.camera) {
                        Button { showCamera = true } label: {
                            Label("Camera", systemImage: "camera")
                        }
                    }
                    Button { showDocPicker = true } label: {
                        Label("Files", systemImage: "folder")
                    }
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 22, weight: .medium))
                        .foregroundStyle(.secondary)
                }
                .disabled(isStreaming)

                // Text input
                TextField("Message Hermes…", text: $text, axis: .vertical)
                    .lineLimit(1...8)
                    .focused($textFocused)
                    .submitLabel(.return)

                // Fixed slot so swapping voice/send/stop (different icon sizes)
                // never changes the pill's height.
                trailingActionButton
                    .frame(width: 30, height: 30)
            }
            .padding(.leading, 14)
            .padding(.trailing, 8)
            .padding(.vertical, 7)
            // Rounded rectangle (not a Capsule): a Capsule's corner radius is half
            // its height, so as the field grows to multiple lines it bulges into a
            // distorted oval. A fixed radius keeps clean curved corners at any height.
            .background(
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .fill(Color(.secondarySystemBackground))
                    .overlay(
                        RoundedRectangle(cornerRadius: 22, style: .continuous)
                            .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
                    )
            )
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
        }
        .background(Color(.systemBackground))
        .photosPicker(isPresented: $showPhotoPicker, selection: $photoItem, matching: .images)
        .onChange(of: photoItem) { _, item in
            Task { await processPhoto(item) }
        }
        .fileImporter(
            isPresented: $showDocPicker,
            allowedContentTypes: [.pdf, .plainText, .data],
            allowsMultipleSelection: false
        ) { result in
            Task { await processDocument(result) }
        }
        .fullScreenCover(isPresented: $showCamera) {
            CameraPicker { image in appendImage(image) }
                .ignoresSafeArea()
        }
        .overlay {
            if isProcessingAttachment {
                ProgressView("Processing…")
                    .padding()
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
            }
        }
        .fullScreenCover(isPresented: $showVoiceMode) {
            VoiceModeView(onDismiss: {
                voice.stop()
                showVoiceMode = false
            })
            .environment(voice)
        }
        .onChange(of: voice.state) { _, newState in
            // Auto-dismiss the overlay if voice reaches idle unexpectedly
            if newState == .idle { showVoiceMode = false }
        }
        // Pop the keyboard when opening a brand-new chat (only drafts — never
        // when opening an existing chat with history). Use onAppear + a detached
        // dispatch (NOT .task): during the NavigationSplitView push the view can
        // appear→disappear→reappear, which cancels a .task before it focuses.
        // The delay lets the field land in the hierarchy and the push settle.
        .onAppear {
            guard chatStore.isDraft(chatId) else { return }
            for delay in [0.4, 0.7, 1.0] {
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                    // Only if still an empty draft AND not already focused — never
                    // re-assert focus on a field that's mid-dictation (can disrupt
                    // or crash the dictation session).
                    if chatStore.isDraft(chatId), !textFocused { textFocused = true }
                }
            }
        }
    }

    // MARK: - Trailing action button (stop / send / voice)

    @ViewBuilder
    private var trailingActionButton: some View {
        if isStreaming {
            Button {
                Task { await chatStore.stopRun(chatId: chatId) }
            } label: {
                Image(systemName: "stop.circle")
                    .font(.system(size: 28))
                    .foregroundStyle(.red)
            }
        } else if hasContent {
            Button { sendMessage() } label: {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.system(size: 28))
                    .foregroundStyle(Color.accentColor)
            }
        } else {
            // Waveform motif (matches the app icon); turns red + animates while a
            // voice session is live.
            Button {
                Haptics.impact(voice.state.isActive ? .medium : .heavy)
                showVoiceMode = true
                voice.toggle(settings: settings, chatStore: chatStore, chatId: chatId)
            } label: {
                Image(systemName: "waveform")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(voice.state.isActive ? Color.red : Color.accentColor)
                    .symbolEffect(.variableColor.iterative, options: .repeating, isActive: voice.state.isActive)
            }
        }
    }

    // MARK: - Actions

    private func sendMessage() {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty || !attachments.isEmpty else { return }

        // End any in-progress keyboard dictation BEFORE we mutate `text`. Dictation
        // commits asynchronously: clearing the field while it's still active can
        // (a) re-insert the just-sent words after we clear, and (b) crash, since the
        // bound text is being mutated out from under the live dictation session.
        // Resigning first responder finalizes dictation so the clear below sticks.
        textFocused = false

        // /image command — route to image generation instead of a normal run
        if attachments.isEmpty, trimmed.lowercased().hasPrefix("/image ") {
            let prompt = String(trimmed.dropFirst(7)).trimmingCharacters(in: .whitespaces)
            guard !prompt.isEmpty else { return }
            clearAfterSend(trimmed)
            Haptics.impact(.medium)
            Task { await chatStore.generateImage(chatId: chatId, prompt: prompt) }
            return
        }

        let imgs = attachments
        clearAfterSend(trimmed)
        attachments = []
        Haptics.impact(.medium)
        Task { await chatStore.startRun(chatId: chatId, text: trimmed, images: imgs) }
    }

    /// Clear the composer and keep it clear against an async dictation commit.
    /// When the mic is still active on send, dictation finalizes a beat later and
    /// re-inserts the just-sent text after we've cleared. Re-clear over a short
    /// window — but ONLY while the box still holds exactly the sent text, so we
    /// never wipe something the user has started typing next.
    private func clearAfterSend(_ sent: String) {
        text = ""
        for delay in [0.1, 0.25, 0.5, 0.8] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                if text.trimmingCharacters(in: .whitespacesAndNewlines) == sent { text = "" }
            }
        }
    }

    // MARK: - Photo processing

    private func processPhoto(_ item: PhotosPickerItem?) async {
        guard let item else { return }
        isProcessingAttachment = true
        defer { isProcessingAttachment = false; photoItem = nil }

        guard let data = try? await item.loadTransferable(type: Data.self),
              let uiImage = UIImage(data: data) else { return }
        appendImage(uiImage)
    }

    /// Resize, JPEG-encode and attach a captured/picked image. Shared by the
    /// photo library and the camera.
    private func appendImage(_ uiImage: UIImage) {
        let resized = resizeImage(uiImage, maxDimension: 1024)
        guard let jpegData = resized.jpegData(compressionQuality: 0.92) else { return }
        let b64 = jpegData.base64EncodedString()
        attachments.append(ChatAttachment(
            type: .image,
            dataUrl: "data:image/jpeg;base64,\(b64)",
            name: "image.jpg",
            mimeType: "image/jpeg",
            size: jpegData.count
        ))
    }

    // MARK: - Document processing (PDF + text files)

    private func processDocument(_ result: Result<[URL], Error>) async {
        isProcessingAttachment = true
        defer { isProcessingAttachment = false }

        guard case .success(let urls) = result, let url = urls.first else { return }
        guard url.startAccessingSecurityScopedResource() else { return }
        defer { url.stopAccessingSecurityScopedResource() }

        let ext = url.pathExtension.lowercased()
        let name = url.lastPathComponent

        if ext == "pdf" {
            // Extract text via server
            guard let client = settings.client,
                  let data = try? Data(contentsOf: url) else { return }
            let text = (try? await client.extractPDF(data)) ?? ""
            if !text.isEmpty {
                attachments.append(ChatAttachment(
                    type: .file,
                    content: text,
                    name: name,
                    mimeType: "application/pdf",
                    size: data.count
                ))
            }
        } else {
            // Plain text / code file
            guard let content = try? String(contentsOf: url, encoding: .utf8) else { return }
            attachments.append(ChatAttachment(
                type: .file,
                content: "```\n\(content)\n```",
                name: name,
                mimeType: "text/plain",
                size: content.utf8.count
            ))
        }
    }

    // MARK: - Image resize

    private func resizeImage(_ image: UIImage, maxDimension: CGFloat) -> UIImage {
        let s = image.size
        let maxSide = max(s.width, s.height)
        guard maxSide > maxDimension else { return image }
        let scale = maxDimension / maxSide
        let newSize = CGSize(width: s.width * scale, height: s.height * scale)
        let renderer = UIGraphicsImageRenderer(size: newSize)
        return renderer.image { _ in image.draw(in: CGRect(origin: .zero, size: newSize)) }
    }

    // MARK: - Attachment chip

    private func attachmentChip(_ att: ChatAttachment, index: Int) -> some View {
        HStack(spacing: 4) {
            if att.type == .image,
               let dataUrl = att.dataUrl,
               let b64 = dataUrl.components(separatedBy: ",").last,
               let data = Data(base64Encoded: b64),
               let img = UIImage(data: data) {
                Image(uiImage: img)
                    .resizable().scaledToFill()
                    .frame(width: 36, height: 36)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
            } else {
                Image(systemName: att.mimeType == "application/pdf" ? "doc.richtext" : "doc.text")
                    .foregroundStyle(.secondary)
            }
            Text(att.name).font(.caption).lineLimit(1)
            Button {
                attachments.remove(at: index)
            } label: {
                Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary).font(.caption)
            }
        }
        .padding(6)
        .background(Color(.systemGray6))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}

// MARK: - CameraPicker (UIImagePickerController wrapper)

struct CameraPicker: UIViewControllerRepresentable {
    var onImage: (UIImage) -> Void
    @Environment(\.dismiss) private var dismiss

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let parent: CameraPicker
        init(_ parent: CameraPicker) { self.parent = parent }

        func imagePickerController(_ picker: UIImagePickerController,
                                   didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            if let image = info[.originalImage] as? UIImage { parent.onImage(image) }
            parent.dismiss()
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            parent.dismiss()
        }
    }
}
