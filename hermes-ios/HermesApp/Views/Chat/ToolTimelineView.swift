import SwiftUI

// MARK: - ToolTimelineView
// Collapses a consecutive run of tool_event messages into a single expandable row.

struct ToolTimelineView: View, Equatable {
    let tools: [ChatMessage]
    @State private var expanded = false

    // Skip re-evaluation unless a tool's identity or progress actually changed —
    // otherwise this row re-renders on every streaming delta (layout-storm source).
    // `@State expanded` is preserved across skips by SwiftUI. (Used via `.equatable()`.)
    static func == (l: ToolTimelineView, r: ToolTimelineView) -> Bool {
        guard l.tools.count == r.tools.count else { return false }
        for (a, b) in zip(l.tools, r.tools) {
            if a.id != b.id
                || a.tool?.completed != b.tool?.completed
                || a.tool?.preview != b.tool?.preview
                || a.tool?.error != b.tool?.error
                || a.tool?.duration != b.tool?.duration
                || a.tool?.resultSummary != b.tool?.resultSummary { return false }
        }
        return true
    }

    private var totalDuration: Double {
        tools.compactMap { $0.tool?.duration }.reduce(0, +)
    }

    private var hasErrors: Bool {
        tools.contains { $0.tool?.error != nil }
    }

    private var allDone: Bool {
        tools.allSatisfy {
            $0.tool?.completed == true || $0.tool?.resultSummary != nil || $0.tool?.error != nil
        }
    }

    private var currentTool: ToolEvent? {
        tools.reversed().compactMap(\.tool).first {
            $0.completed != true && $0.resultSummary == nil && $0.error == nil
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Summary row (always visible)
            Button {
                withAnimation(.easeInOut(duration: 0.18)) { expanded.toggle() }
            } label: {
                HStack(spacing: 8) {
                    // Status icon
                    Group {
                        if !allDone {
                            ProgressView().scaleEffect(0.65)
                        } else if hasErrors {
                            Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.red)
                        } else {
                            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                        }
                    }
                    .frame(width: 18)

                    Text(summaryText)
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    if totalDuration > 0 {
                        Text(String(format: "%.1fs", totalDuration))
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }

                    Spacer()

                    Image(systemName: expanded ? "chevron.up" : "chevron.down")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(Color(.systemGray6))
                .clipShape(RoundedRectangle(cornerRadius: 8))
            }
            .buttonStyle(.plain)

            // Expanded tool list
            if expanded {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(tools) { msg in
                        if let tool = msg.tool {
                            ToolRowView(tool: tool)
                        }
                    }
                }
                .padding(.top, 4)
                .padding(.leading, 8)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 3)
    }

    private var summaryText: String {
        if let currentTool {
            return ToolActivityPresenter.statusText(for: currentTool)
        }
        let n = tools.count
        if n == 1, let tool = tools.first?.tool {
            return ToolActivityPresenter.rowText(for: tool)
        }
        return "\(n) actions completed"
    }
}

// MARK: - ToolRowView (single tool in the expanded timeline)

private struct ToolRowView: View {
    let tool: ToolEvent

    var body: some View {
        HStack(spacing: 6) {
            // Status dot
            Circle()
                .fill(statusColor)
                .frame(width: 6, height: 6)

            Text(ToolActivityPresenter.rowText(for: tool))
                .font(.caption)
                .foregroundStyle(.primary)
                .lineLimit(1)

            if let dur = tool.duration {
                Text(String(format: "%.1fs", dur))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }

            Spacer()

            if let summary = tool.resultSummary {
                Text(summary)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            } else if let err = tool.error {
                Text(err)
                    .font(.caption2)
                    .foregroundStyle(.red)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .background(Color(.systemGray6).opacity(0.5))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    private var statusColor: Color {
        if tool.error != nil { return .red }
        if tool.completed == true || tool.resultSummary != nil { return .green }
        return .orange
    }
}
