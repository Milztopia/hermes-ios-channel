import SwiftUI
import UIKit

// MARK: - VoiceModeView
// Full-screen voice overlay: a live transcript of the spoken response (scrolling
// + word highlight in sync with speech) above an audio-reactive orb sitting low
// on the screen.

struct VoiceModeView: View {
    @Environment(VoiceCoordinator.self) private var voice
    @Environment(ChatStore.self) private var chatStore
    @Environment(\.scenePhase) private var scenePhase
    let onDismiss: () -> Void

    var body: some View {
        ZStack {
            Color.black.opacity(0.82)
                .ignoresSafeArea()

            GeometryReader { geometry in
                // Every non-transcript element owns a permanent slot. State
                // changes replace or fade content inside those slots instead of
                // inserting/removing views and reflowing the entire screen.
                let transcriptHeight = max(150, min(280, geometry.size.height - 555))

                VStack(spacing: 0) {
                    ZStack {
                        if !voice.spokenText.isEmpty {
                            TranscriptView(text: voice.spokenText, charIndex: voice.spokenCharIndex)
                                .padding(.horizontal, 26)
                                .frame(maxWidth: .infinity)
                        }
                    }
                    .frame(height: transcriptHeight)

                    Spacer(minLength: 4)

                    OrbView(level: orbLevel, color: ringColor,
                            ringsActive: scenePhase == .active &&
                                (voice.state == .recording || voice.state == .waitingForSpeech || voice.state == .speaking),
                            icon: micIcon)
                        .frame(width: 200, height: 200)

                    Text(statusText)
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(.white)
                        .multilineTextAlignment(.center)
                        .lineLimit(2)
                        .minimumScaleFactor(0.72)
                        .frame(height: 44)
                        .padding(.horizontal, 24)

                    GateControl(
                        level: voice.meterLevel,
                        peak: voice.meterPeak,
                        closure: voice.gateClosure,
                        gate: Binding(
                            get: { voice.gateLevel },
                            set: { voice.setGateLevel($0) }
                        )
                    )
                    .frame(height: 82)
                    .padding(.horizontal, 22)
                    .contentShape(Rectangle())

                    HStack(spacing: 10) {
                        Label("Barge-in", systemImage: "waveform.badge.mic")
                            .font(.subheadline.weight(.medium))
                        Toggle("", isOn: Binding(
                            get: { voice.isBargeInEnabled },
                            set: { voice.setBargeInEnabled($0) }
                        ))
                        .labelsHidden()
                        .tint(.green)
                    }
                    .foregroundStyle(.white.opacity(0.85))
                    .padding(.leading, 14)
                    .padding(.trailing, 8)
                    .padding(.vertical, 7)
                    .background(Capsule().fill(.white.opacity(0.10)))
                    .frame(height: 50)

                    HStack(spacing: 8) {
                        ProgressView().tint(.white)
                        Text("Loading speech model…")
                            .font(.caption).foregroundStyle(.white.opacity(0.7))
                    }
                    .opacity(voice.whisperService.isLoading ? 1 : 0)
                    .frame(height: 30)

                    // Send and Interrupt occupy the same permanent action slot.
                    ZStack {
                        voiceActionButton(
                            title: "Send",
                            icon: "arrow.up.circle.fill",
                            color: .green,
                            action: voice.forceSend
                        )
                        .opacity(voice.canForceSend ? 1 : 0)
                        .allowsHitTesting(voice.canForceSend)

                        voiceActionButton(
                            title: "Interrupt",
                            icon: "stop.circle.fill",
                            color: .red,
                            action: voice.interrupt
                        )
                        .opacity(voice.canInterrupt ? 1 : 0)
                        .allowsHitTesting(voice.canInterrupt)
                    }
                    .frame(height: 64)

                    Button(action: onDismiss) {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 44))
                            .foregroundStyle(.white.opacity(0.6))
                    }
                    .frame(height: 70)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(.top, 12)
                .padding(.bottom, 12)
            }
        }
        .transition(.opacity.combined(with: .scale(scale: 0.97)))
        // Keep the screen awake for the whole voice session.
        .onAppear { UIApplication.shared.isIdleTimerDisabled = true }
        // Catch-all: release the mic + re-enable auto-lock whenever this view
        // goes away (X, swipe, navigating away, parent dismissal). Locking the
        // screen does NOT trigger this, so the voice turn keeps running in the
        // background (enabled via the `audio` background mode).
        .onDisappear {
            voice.stop()
            UIApplication.shared.isIdleTimerDisabled = false
        }
    }

    private var orbLevel: Float {
        switch voice.state {
        case .speaking:                      return voice.speakingLevel
        case .recording, .waitingForSpeech:  return voice.audioLevel
        default:                             return 0
        }
    }

    private var ringColor: Color {
        switch voice.state {
        case .recording:    return .green
        case .transcribing: return .yellow
        case .running:      return .blue
        case .speaking:     return .purple
        case .error:        return .red
        default:            return .accentColor
        }
    }

    private var micIcon: String {
        switch voice.state {
        case .transcribing: return "waveform"
        case .running:      return "brain"
        case .speaking:     return "speaker.wave.2.fill"
        default:            return "mic.fill"
        }
    }

    private var statusText: String {
        if voice.state == .running, let toolText = currentToolStatus {
            return toolText
        }
        return voice.state.label
    }

    private var currentToolStatus: String? {
        for message in toolActivityMessages.reversed() {
            guard let tool = message.tool,
                  tool.completed != true,
                  tool.resultSummary == nil,
                  tool.error == nil else { continue }
            return ToolActivityPresenter.statusText(for: tool)
        }
        return nil
    }

    private var toolActivityMessages: [ChatMessage] {
        guard let chatId = chatStore.activeChatId,
              let messages = chatStore.messages[chatId] else { return [] }
        return messages.filter { $0.type == .toolEvent && $0.tool != nil }
    }

    private func voiceActionButton(
        title: String,
        icon: String,
        color: Color,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Label(title, systemImage: icon)
                .font(.system(size: 19, weight: .semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 24)
                .padding(.vertical, 12)
                .background(Capsule().fill(color.opacity(0.9)))
        }
    }
}

// MARK: - Live microphone gate

private struct GateControl: View {
    let level: Float
    let peak: Float
    let closure: Float
    @Binding var gate: Double
    @State private var isDragging = false

    private var gateDisplayLevel: CGFloat {
        CGFloat(max(0, min(1, gate)))
    }

    private var gateDB: Double {
        -54 + 36 * gate
    }

    var body: some View {
        VStack(spacing: 5) {
            HStack {
                Text("Mic gate")
                    .font(.caption.weight(.semibold))
                Spacer()
                Text(gateDescription)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.white.opacity(0.65))
            }

            GeometryReader { geometry in
                let width = geometry.size.width
                let height = geometry.size.height
                // Keep the handle inside the meter even at 0% and 100%, so it can
                // always be grabbed and dragged back from either extreme.
                let handleInset: CGFloat = 10
                let thresholdX = handleInset
                    + gateDisplayLevel * max(1, width - handleInset * 2)
                let signalX = max(2, min(width, CGFloat(level) * width))
                let redX = width - CGFloat(closure) * max(0, width - thresholdX)
                ZStack {
                    RoundedRectangle(cornerRadius: 7)
                        .fill(.white.opacity(0.07))

                    LinearGradient(
                        colors: [.green.opacity(0.8), .green, .yellow, .red],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                    .frame(width: signalX, height: max(8, height * 0.42))
                    .clipShape(RoundedRectangle(cornerRadius: 3))
                    .frame(maxWidth: .infinity, alignment: .leading)

                    HStack(spacing: 0) {
                        ForEach(0..<20, id: \.self) { _ in
                            Rectangle()
                                .fill(Color.black.opacity(0.24))
                                .frame(width: 1)
                            Spacer(minLength: 0)
                        }
                    }
                    .frame(height: max(8, height * 0.42))

                    Rectangle()
                        .fill(.white.opacity(0.9))
                        .frame(width: 2, height: max(12, height * 0.55))
                        .position(x: max(1, min(width - 1, CGFloat(peak) * width)), y: height / 2)

                    // Adjustable threshold.
                    Path { path in
                        path.move(to: CGPoint(x: thresholdX, y: 2))
                        path.addLine(to: CGPoint(x: thresholdX, y: height - 2))
                    }
                    .stroke(Color.yellow, style: StrokeStyle(lineWidth: 2, dash: [3, 3]))

                    Circle()
                        .fill(Color.white)
                        .overlay(Circle().stroke(Color.yellow, lineWidth: 2))
                        .frame(width: 16, height: 16)
                        .shadow(color: .black.opacity(0.65), radius: 3)
                        .position(x: thresholdX, y: height / 2)

                    if isDragging {
                        Text(String(format: "%.1f dB", gateDB))
                            .font(.caption2.monospacedDigit().weight(.semibold))
                            .foregroundStyle(.black)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 4)
                            .background(
                                RoundedRectangle(cornerRadius: 6)
                                    .fill(Color.white)
                                    .shadow(color: .black.opacity(0.5), radius: 3)
                            )
                            .position(
                                x: max(32, min(width - 32, thresholdX)),
                                y: -11
                            )
                    }

                    // Gate pressure closes from right → threshold. It snaps back
                    // to the right the instant the input crosses the threshold.
                    Path { path in
                        path.move(to: CGPoint(x: redX, y: 3))
                        path.addLine(to: CGPoint(x: redX, y: height - 3))
                    }
                    .stroke(Color.red, lineWidth: 3)
                    .shadow(color: .red.opacity(0.7), radius: 2)

                    Path { path in
                        path.addRect(CGRect(x: redX, y: 0, width: max(0, width - redX), height: height))
                    }
                    .fill(Color.red.opacity(0.10))
                }
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            isDragging = true
                            gate = max(0, min(1,
                                Double((value.location.x - handleInset)
                                    / max(1, width - handleInset * 2))))
                        }
                        .onEnded { _ in isDragging = false }
                )
                .accessibilityLabel("Microphone gate")
                .accessibilityValue(gateDescription)
            }
            .frame(height: 42)
        }
        .foregroundStyle(.white.opacity(0.88))
    }

    private var gateDescription: String {
        switch gate {
        case ..<0.25: return "Whisper"
        case ..<0.52: return "Quiet"
        case ..<0.76: return "Noisy"
        default: return "Very loud"
        }
    }
}

// MARK: - OrbView (breathing + audio-reactive)

private struct OrbView: View {
    let level: Float        // 0..1 reactive amplitude (mic or TTS)
    let color: Color
    let ringsActive: Bool
    let icon: String

    @State private var breathe = false

    var body: some View {
        ZStack {
            PulsingRings(color: color, isActive: ringsActive)

            Circle().fill(color.opacity(0.2)).frame(width: 120, height: 120)

            // Core: size reacts to the live level; a gentle always-on breathing
            // scale keeps it alive even when idle/thinking.
            Circle()
                .fill(color)
                .frame(width: 80 + CGFloat(level) * 30, height: 80 + CGFloat(level) * 30)
                .scaleEffect(breathe ? 1.04 : 0.97)
                .animation(.linear(duration: 0.1), value: level)
                .animation(.easeInOut(duration: 1.6).repeatForever(autoreverses: true), value: breathe)

            Image(systemName: icon)
                .font(.system(size: 30, weight: .medium))
                .foregroundStyle(.white)
        }
        .frame(width: 200, height: 200)
        .onAppear { breathe = true }
    }
}

// MARK: - PulsingRings (steady breathing rings when active)

private struct PulsingRings: View {
    let color: Color
    let isActive: Bool
    @State private var animate = false

    var body: some View {
        ZStack {
            ForEach(0..<3, id: \.self) { i in
                let diameter: CGFloat = 130 + CGFloat(i) * 28
                Circle()
                    .stroke(color.opacity(max(0, 0.45 - Double(i) * 0.12)), lineWidth: 1.5)
                    .frame(width: diameter, height: diameter)
                    .scaleEffect(isActive && animate ? 1 + CGFloat(i) * 0.08 : 1)
                    .opacity(isActive ? 1 : 0.4)
                    .animation(.easeInOut(duration: 1.2).repeatForever(autoreverses: true).delay(Double(i) * 0.4),
                               value: animate)
            }
        }
        .onAppear { animate = true }
    }
}

// MARK: - TranscriptView (karaoke: scrolls + bolds words as spoken)

private struct TranscriptView: View {
    let text: String
    let charIndex: Int

    // Split into sentence segments with their global character offsets so we
    // can scroll the currently-spoken sentence into the middle.
    private var segments: [(start: Int, str: String)] {
        var segs: [(Int, String)] = []
        var start = 0, idx = 0, cur = ""

        func appendVisibleSegment() {
            let chars = Array(cur)
            guard let first = chars.firstIndex(where: { !$0.isWhitespace }),
                  let last = chars.lastIndex(where: { !$0.isWhitespace }) else {
                return
            }
            // Paragraph separators belong to the source text (and therefore its
            // karaoke offsets), but should not become tall blank Text rows. Shift
            // the visible segment's global start by exactly what was omitted.
            segs.append((start + first, String(chars[first...last])))
        }

        let chars = Array(text)
        while idx < chars.count {
            let ch = chars[idx]
            cur.append(ch)
            idx += 1
            if ".!?".contains(ch) {
                while idx < chars.count, "\"'”’)]}".contains(chars[idx]) {
                    cur.append(chars[idx])
                    idx += 1
                }
                appendVisibleSegment()
                start = idx
                cur = ""
            } else if ch == "\n" {
                appendVisibleSegment()
                start = idx
                cur = ""
            }
        }
        appendVisibleSegment()
        return segs.isEmpty ? [(0, text)] : segs
    }

    var body: some View {
        let segs = segments
        let currentIdx = segs.lastIndex(where: { $0.start < charIndex }) ?? 0
        ScrollViewReader { proxy in
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(Array(segs.enumerated()), id: \.offset) { idx, seg in
                        Text(styled(seg.str, globalStart: seg.start))
                            .multilineTextAlignment(.leading)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .id(idx)
                    }
                }
                .padding(.vertical, 52)   // lets the first/last line reach center
            }
            .frame(height: 300)            // ~10 lines
            .mask(
                LinearGradient(colors: [.clear, .white, .white, .clear],
                               startPoint: .top, endPoint: .bottom)
            )
            .onChange(of: currentIdx) {
                guard UIApplication.shared.applicationState == .active else { return }
                // Scroll once per sentence, not once per karaoke character. The
                // former 33 Hz animated scroll loop caused overlapping SwiftUI
                // layout passes and background watchdog terminations.
                proxy.scrollTo(currentIdx, anchor: .center)
            }
            .onChange(of: segs.count) {
                guard UIApplication.shared.applicationState == .active else { return }
                proxy.scrollTo(currentIdx, anchor: .center)
            }
        }
    }

    // Spoken characters → white; not-yet-spoken → dim grey. Both portions use
    // identical typography so highlighting never changes glyph widths, line
    // wrapping, or the transcript's height while it is being spoken.
    private func styled(_ s: String, globalStart: Int) -> AttributedString {
        let chars = Array(s)
        let split = max(0, min(chars.count, charIndex - globalStart))
        var spoken = AttributedString(String(chars[0..<split]))
        spoken.foregroundColor = .white
        spoken.font = .title3
        var rest = AttributedString(String(chars[split...].prefix(chars.count - split)))
        rest.foregroundColor = .white.opacity(0.35)
        rest.font = .title3
        return spoken + rest
    }
}
