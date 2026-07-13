import SwiftUI
import NocturnalCore

struct ApprovalSheet: View {
    let session: Session
    let request: ApprovalRequest
    @Bindable var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @FocusState private var focusedAction: ActionFocus?
    @State private var isSubmitting = false

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
                .disabled(isSubmitting)

                Spacer()

                Button("Deny") {
                    submit(approved: false)
                }
                .keyboardShortcut("d", modifiers: [])
                .focused($focusedAction, equals: .deny)
                .disabled(isSubmitting)
                .accessibilityLabel("Deny \(request.toolName)")

                Button("Approve") {
                    submit(approved: true)
                }
                .buttonStyle(.borderedProminent)
                .tint(NocturnalPalette.accentAttention)
                // Return is the default action for the simple approve sheet.
                .keyboardShortcut(.defaultAction)
                .focused($focusedAction, equals: .approve)
                .disabled(isSubmitting)
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

    private func submit(approved: Bool) {
        guard !isSubmitting else { return }
        isSubmitting = true
        Task {
            let ok = await model.approve(request, approved: approved)
            if ok {
                dismiss()
            } else {
                isSubmitting = false
            }
        }
    }
}

struct QuestionSheet: View {
    let session: Session
    let prompt: QuestionPrompt
    @Bindable var model: AppModel
    @Environment(\.dismiss) private var dismiss

    @State private var answerText: String = ""
    @State private var isSubmitting = false
    @FocusState private var answerFocused: Bool

    private var canSend: Bool {
        !answerText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !isSubmitting
    }

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
                        .disabled(isSubmitting)
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
                .disabled(isSubmitting)
                .accessibilityLabel("Answer text")
            }

            HStack {
                Button("Cancel") {
                    dismiss()
                    model.dismissSheets()
                }
                .keyboardShortcut(.cancelAction)
                .disabled(isSubmitting)

                Spacer()

                Button("Send") {
                    submitAnswer()
                }
                .buttonStyle(.borderedProminent)
                .tint(NocturnalPalette.accentAttention)
                // Multiline field: Command-Return sends; bare Return inserts a newline.
                .keyboardShortcut(.return, modifiers: [.command])
                .disabled(!canSend)
                .accessibilityLabel("Send answer")
                .accessibilityHint("Command-Return to send")
            }
        }
        .padding(20)
        .frame(minWidth: 360, minHeight: 240)
        .background(NocturnalPalette.bgBase)
        .onAppear { answerFocused = true }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Question for \(session.title)")
    }

    private func submitAnswer() {
        guard canSend else { return }
        isSubmitting = true
        Task {
            let ok = await model.answer(prompt, text: answerText)
            if ok {
                dismiss()
            } else {
                isSubmitting = false
            }
        }
    }
}
