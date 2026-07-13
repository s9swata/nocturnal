import SwiftUI
import NocturnalCore

struct ApprovalSheet: View {
    let session: Session
    let request: ApprovalRequest
    @Bindable var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @FocusState private var focusedAction: ActionFocus?

    private enum ActionFocus: Hashable {
        case deny
        case approve
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 8) {
                Image(systemName: "hand.raised.fill")
                    .foregroundStyle(NocturnalPalette.accentAttention)
                    .accessibilityHidden(true)
                Text("Approve request?")
                    .font(.headline)
                    .foregroundStyle(NocturnalPalette.fgPrimary)
            }

            VStack(alignment: .leading, spacing: 6) {
                LabeledContent("Session", value: session.title)
                LabeledContent("Tool", value: request.toolName)
                LabeledContent("Risk", value: request.riskHint.rawValue.capitalized)
            }
            .font(.subheadline)
            .foregroundStyle(NocturnalPalette.fgSecondary)

            Text(request.summary)
                .font(.body)
                .foregroundStyle(NocturnalPalette.fgPrimary)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityLabel("Summary: \(request.summary)")

            if let detail = request.detail, !detail.isEmpty {
                ScrollView {
                    Text(detail)
                        .font(.caption.monospaced())
                        .foregroundStyle(NocturnalPalette.fgSecondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                }
                .frame(maxHeight: 120)
                .padding(10)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(NocturnalPalette.bgElevated)
                )
                .accessibilityLabel("Detail: \(detail)")
            }

            HStack {
                Button("Cancel") {
                    dismiss()
                    model.dismissSheets()
                }
                .keyboardShortcut(.cancelAction)

                Spacer()

                Button("Deny") {
                    Task {
                        await model.approve(request, approved: false)
                        dismiss()
                    }
                }
                .keyboardShortcut("d", modifiers: [])
                .focused($focusedAction, equals: .deny)
                .accessibilityLabel("Deny \(request.toolName)")

                Button("Approve") {
                    Task {
                        await model.approve(request, approved: true)
                        dismiss()
                    }
                }
                .buttonStyle(.borderedProminent)
                .tint(NocturnalPalette.accentAttention)
                .keyboardShortcut(.defaultAction)
                .focused($focusedAction, equals: .approve)
                .accessibilityLabel("Approve \(request.toolName)")
            }
        }
        .padding(20)
        .frame(minWidth: 360, minHeight: 220)
        .background(NocturnalPalette.bgBase)
        .onAppear { focusedAction = .approve }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Approval for \(request.toolName)")
    }
}

struct QuestionSheet: View {
    let session: Session
    let prompt: QuestionPrompt
    @Bindable var model: AppModel
    @Environment(\.dismiss) private var dismiss

    @State private var answerText: String = ""
    @FocusState private var answerFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 8) {
                Image(systemName: "questionmark.circle.fill")
                    .foregroundStyle(NocturnalPalette.accentAttention)
                    .accessibilityHidden(true)
                Text("Agent question")
                    .font(.headline)
                    .foregroundStyle(NocturnalPalette.fgPrimary)
            }

            Text(session.title)
                .font(.caption)
                .foregroundStyle(NocturnalPalette.fgSecondary)

            Text(prompt.prompt)
                .font(.body)
                .foregroundStyle(NocturnalPalette.fgPrimary)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityLabel("Question: \(prompt.prompt)")

            if !prompt.choices.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(prompt.choices, id: \.self) { choice in
                        Button {
                            answerText = choice
                        } label: {
                            Text(choice)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .accessibilityLabel("Choose \(choice)")
                    }
                }
            }

            if prompt.allowFreeform || prompt.choices.isEmpty {
                TextField(
                    prompt.placeholder ?? "Your answer",
                    text: $answerText,
                    axis: .vertical
                )
                .lineLimit(2...5)
                .textFieldStyle(.roundedBorder)
                .focused($answerFocused)
                .accessibilityLabel("Answer text")
            }

            HStack {
                Button("Cancel") {
                    dismiss()
                    model.dismissSheets()
                }
                .keyboardShortcut(.cancelAction)

                Spacer()

                Button("Send") {
                    Task {
                        await model.answer(prompt, text: answerText)
                        dismiss()
                    }
                }
                .buttonStyle(.borderedProminent)
                .tint(NocturnalPalette.accentAttention)
                .keyboardShortcut(.defaultAction)
                .disabled(answerText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .accessibilityLabel("Send answer")
            }
        }
        .padding(20)
        .frame(minWidth: 360, minHeight: 240)
        .background(NocturnalPalette.bgBase)
        .onAppear { answerFocused = true }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Question for \(session.title)")
    }
}
