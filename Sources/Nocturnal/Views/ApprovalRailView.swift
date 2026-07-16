import SwiftUI
import NocturnalCore

/// Pinned permission surface for the expanded overlay (not only a sheet).
struct ApprovalRailView: View {
    let session: Session
    let request: ApprovalRequest
    @Bindable var model: AppModel

    @State private var isSubmitting = false
    @State private var showNote = false
    @State private var noteText = ""
    @State private var alwaysAllow = false
    @State private var flashRecorded: String?

    private var planSteps: [String]? {
        guard let detail = request.detail else { return nil }
        return SessionPresentation.planSteps(from: detail)
    }

    private var codeLike: Bool {
        guard let detail = request.detail else { return false }
        return SessionPresentation.looksLikeCode(detail)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let flashRecorded {
                HStack(spacing: 8) {
                    Image(systemName: "checkmark.circle")
                        .foregroundStyle(NocturnalPalette.accentSuccess)
                    Text(flashRecorded)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(NocturnalPalette.accentSuccess)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(NocturnalPalette.accentSuccess.opacity(0.12))
                )
                .accessibilityLabel(flashRecorded)
            } else {
                HStack(spacing: 8) {
                    Circle()
                        .fill(NocturnalPalette.accentAttention)
                        .frame(width: 7, height: 7)
                    Text("Permission requested")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(NocturnalPalette.accentAttention)
                        .textCase(.uppercase)
                    Spacer()
                    Text(session.title)
                        .font(.caption2)
                        .foregroundStyle(NocturnalPalette.fgSecondary)
                        .lineLimit(1)
                }

                Text(request.toolName)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(NocturnalPalette.fgPrimary)

                Text(request.summary)
                    .font(.caption)
                    .foregroundStyle(NocturnalPalette.fgSecondary)
                    .fixedSize(horizontal: false, vertical: true)

                if let steps = planSteps {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(Array(steps.enumerated()), id: \.offset) { _, step in
                            Text(step)
                                .font(.caption)
                                .foregroundStyle(NocturnalPalette.fgPrimary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    .padding(8)
                    .background(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(NocturnalPalette.bgElevated)
                    )
                } else if let detail = request.detail, !detail.isEmpty {
                    ScrollView {
                        Text(detail)
                            .font(codeLike ? .caption.monospaced() : .caption)
                            .foregroundStyle(NocturnalPalette.fgSecondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                    }
                    .frame(maxHeight: codeLike ? 120 : 72)
                    .padding(8)
                    .background(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(NocturnalPalette.bgElevated)
                    )
                }

                Toggle("Always allow this tool (session)", isOn: $alwaysAllow)
                    .font(.caption2)
                    .foregroundStyle(NocturnalPalette.fgSecondary)
                    .disabled(isSubmitting)

                if showNote {
                    TextField("Denial note", text: $noteText)
                        .textFieldStyle(.roundedBorder)
                        .font(.caption)
                        .disabled(isSubmitting)
                }

                HStack(spacing: 8) {
                    if !showNote {
                        Button("Note…") { showNote = true }
                            .buttonStyle(.borderless)
                            .font(.caption)
                            .foregroundStyle(NocturnalPalette.fgSecondary)
                            .disabled(isSubmitting)
                    }
                    Button("Deny") {
                        submit(approved: false)
                    }
                    .buttonStyle(.borderless)
                    .font(.caption)
                    .foregroundStyle(NocturnalPalette.accentDanger)
                    .disabled(isSubmitting)

                    Spacer()

                    Button("Allow") {
                        submit(approved: true)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .tint(NocturnalPalette.accentAttention)
                    .disabled(isSubmitting)
                }

                Text("Records a local decision — does not claim the agent accepted it.")
                    .font(.caption2)
                    .foregroundStyle(NocturnalPalette.fgSecondary.opacity(0.75))
            }
        }
        .padding(.horizontal, NocturnalLayout.contentPadding)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(NocturnalPalette.bgElevated)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Permission requested for \(request.toolName)")
    }

    private func submit(approved: Bool) {
        guard !isSubmitting else { return }
        isSubmitting = true
        let scope: ApprovalScope = (approved && alwaysAllow) ? .sessionTool : .once
        let note: String? = {
            guard !approved else { return nil }
            let t = noteText.trimmingCharacters(in: .whitespacesAndNewlines)
            return t.isEmpty ? nil : t
        }()
        Task {
            let ok = await model.approve(request, approved: approved, note: note, scope: scope)
            if ok {
                flashRecorded = approved ? "Recorded approval" : "Recorded denial"
                try? await Task.sleep(nanoseconds: 600_000_000)
                flashRecorded = nil
            }
            isSubmitting = false
        }
    }
}
