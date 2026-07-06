import SwiftUI

// MARK: - ImageLightboxView
// Full-screen image viewer with pinch-to-zoom, tap-to-dismiss, and share.

struct ImageLightboxView: View {
    let image: UIImage
    let onDismiss: () -> Void

    @State private var scale: CGFloat = 1.0
    @State private var lastScale: CGFloat = 1.0
    @State private var offset: CGSize = .zero
    @State private var lastOffset: CGSize = .zero

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            Image(uiImage: image)
                .resizable()
                .scaledToFit()
                .scaleEffect(scale)
                .offset(offset)
                .gesture(dragGesture)
                .gesture(magnifyGesture)
                .onTapGesture(count: 2) {
                    withAnimation(.spring()) {
                        if scale > 1.2 {
                            scale = 1; lastScale = 1
                            offset = .zero; lastOffset = .zero
                        } else {
                            scale = 2.5; lastScale = 2.5
                        }
                    }
                }

            // Controls overlay
            VStack {
                HStack {
                    Spacer()
                    Button(action: onDismiss) {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 30))
                            .foregroundStyle(.white.opacity(0.85))
                            .shadow(radius: 4)
                    }
                    .padding(16)
                }
                Spacer()
                HStack {
                    Spacer()
                    ShareLink(
                        item: Image(uiImage: image),
                        preview: SharePreview("Image", image: Image(uiImage: image))
                    ) {
                        Image(systemName: "square.and.arrow.up.circle.fill")
                            .font(.system(size: 30))
                            .foregroundStyle(.white.opacity(0.85))
                            .shadow(radius: 4)
                    }
                    .padding(16)
                }
            }
        }
        .statusBarHidden()
        .transition(.opacity)
    }

    private var magnifyGesture: some Gesture {
        MagnificationGesture()
            .onChanged { value in
                scale = max(1, min(lastScale * value, 8))
            }
            .onEnded { value in
                lastScale = scale
                if scale < 1.05 {
                    withAnimation(.spring()) { scale = 1; lastScale = 1; offset = .zero; lastOffset = .zero }
                }
            }
    }

    private var dragGesture: some Gesture {
        DragGesture()
            .onChanged { value in
                guard scale > 1 else { return }
                offset = CGSize(
                    width: lastOffset.width + value.translation.width,
                    height: lastOffset.height + value.translation.height
                )
            }
            .onEnded { _ in
                lastOffset = offset
            }
    }
}
