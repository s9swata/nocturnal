import SwiftUI
import NocturnalCore

struct ApprovalSheet: View {
    let session: Session
    let request: ApprovalRequest
    @Bindable var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @FocusState private var focusedAction: ActionFocus?
    @State private var isSubmitting = false
    @State private var showNoteField = false
    @State private var noteText = ""
    @State private var alwaysAllowThisSession = false

    private enum ActionFocus: Hashable {
        case deny
        case approve
        case note
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            // Banner
            HStack(spacing: 8) {
                Circle()
                    .fill(NocturnalPalette.accentAttention)
                    .frame(width: 7, height: 7)
                    .accessibilityHidden(true)
                Text("Permission requested")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(NocturnalPalette.accentAttention)
                    .textCase(.uppercase)
                Spacer()
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(NocturnalPalette.accentAttention.opacity(0.12))
            )
            .accessibilityLabel("Permission requested")

            VStack(alignment: .leading, spacing: 6) {
                Text(session.title)
                    .font(.caption)
                    .foregroundStyle(NocturnalPalette.fgSecondary)
                Text(request.toolName)
                    .font(.headline)
                    .foregroundStyle(NocturnalPalette.fgPrimary)
                if request.riskHint != .unknown {
                    Text("Risk: \(request.riskHint.rawValue.capitalized)")
                        .font(.caption2)
                        .foregroundStyle(NocturnalPalette.fgSecondary)
                }
            }

            Text(request.summary)
                .font(.subheadline)
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
                .frame(maxHeight: 140)
                .padding(10)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(NocturnalPalette.bgElevated)
                )
                .accessibilityLabel("Detail: \(detail)")
            }

            Toggle("Always allow this tool (this session)", isOn: $alwaysAllowThisSession)
                .font(.caption)
                .foregroundStyle(NocturnalPalette.fgSecondary)
                .disabled(isSubmitting)
                .help("Local sticky only — records allow for matching tools in Nocturnal. Does not change agent global settings.")
                .accessibilityHint("Local policy only. Does not claim the agent accepted always-allow.")

            if showNoteField {
                TextField("Feedback note (optional)", text: $noteText, axis: .vertical)
                    .lineLimit(2...4)
                    .textFieldStyle(.roundedBorder)
                    .focused($focusedAction, equals: .note)
                    .disabled(isSubmitting)
                    .accessibilityLabel("Denial note")
            }

            HStack {
                Button("Cancel") {
                    dismiss()
                    model.dismissSheets()
                }
                .keyboardShortcut(.cancelAction)
                .disabled(isSubmitting)

                Spacer()

                if !showNoteField {
                    Button("Deny with note…") {
                        showNoteField = true
                        focusedAction = .note
                    }
                    .buttonStyle(.borderless)
                    .font(.caption)
                    .foregroundStyle(NocturnalPalette.fgSecondary)
                    .disabled(isSubmitting)
                }

                Button("Deny") {
                    submit(approved: false)
                }
                .keyboardShortcut("d", modifiers: [])
                .focused($focusedAction, equals: .deny)
                .disabled(isSubmitting)
                .foregroundStyle(NocturnalPalette.accentDanger)
                .accessibilityLabel("Deny \(request.toolName)")

                Button("Allow") {
                    submit(approved: true)
                }
                .buttonStyle(.borderedProminent)
                .tint(NocturnalPalette.accentAttention)
                .keyboardShortcut(.defaultAction)
                .focused($focusedAction, equals: .approve)
                .disabled(isSubmitting)
                .accessibilityLabel("Allow \(request.toolName)")
            }

            Text("Records a local decision file. Does not claim the agent consumed it.")
                .font(.caption2)
                .foregroundStyle(NocturnalPalette.fgSecondary.opacity(0.8))
        }
        .padding(20)
        .frame(minWidth: 380, minHeight: 260)
        .background(NocturnalPalette.bgBase)
        .onAppear { focusedAction = .approve }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Approval for \(request.toolName)")
    }

    private func submit(approved: Bool) {
        guard !isSubmitting else { return }
        isSubmitting = true
        let scope: ApprovalScope = (approved && alwaysAllowThisSession) ? .sessionTool : .once
        let note: String? = {
            if approved { return nil }
            let trimmed = noteText.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }()
        Task {
            let ok = await model.approve(request, approved: approved, note: note, scope: scope)
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
    @State private var selectedChoice: String?
    @State private var useOther = false
    @State private var isSubmitting = false
    @FocusState private var answerFocused: Bool

    private var effectiveAnswer: String {
        if useOther || prompt.choices.isEmpty {
            return answerText
        }
        return selectedChoice ?? answerText
    }

    private var canSend: Bool {
        !effectiveAnswer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !isSubmitting
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
                            selectedChoice = choice
                            useOther = false
                            answerText = choice
                        } label: {
                            HStack(spacing: 8) {
                                Image(systemName: selectedChoice == choice && !useOther
                                      ? "largecircle.fill.circle"
                                      : "circle")
                                    .font(.caption)
                                    .foregroundStyle(
                                        selectedChoice == choice && !useOther
                                            ? NocturnalPalette.accentAttention
                                            : NocturnalPalette.fgSecondary
                                    )
                                Text(choice)
                                    .font(.subheadline)
                                    .foregroundStyle(NocturnalPalette.fgPrimary)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .padding(.horizontal, 10)
                            .padding(.vertical, 8)
                            .background(
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .fill(
                                        selectedChoice == choice && !useOther
                                            ? NocturnalPalette.bgHighlight
                                            : NocturnalPalette.bgElevated
                                    )
                            )
                        }
                        .buttonStyle(.plain)
                        .disabled(isSubmitting)
                        .accessibilityLabel("Choose \(choice)")
                        .accessibilityAddTraits(selectedChoice == choice && !useOther ? .isSelected : [])
                    }

                    if prompt.allowFreeform {
                        Button {
                            let wasChoice = selectedChoice
                            useOther = true
                            selectedChoice = nil
                            if let wasChoice, answerText == wasChoice {
                                answerText = ""
                            }
                        } label: {
                            HStack(spacing: 8) {
                                Image(systemName: useOther ? "largecircle.fill.circle" : "circle")
                                    .font(.caption)
                                    .foregroundStyle(
                                        useOther
                                            ? NocturnalPalette.accentAttention
                                            : NocturnalPalette.fgSecondary
                                    )
                                Text("Other…")
                                    .font(.subheadline)
                                    .foregroundStyle(NocturnalPalette.fgPrimary)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .padding(.horizontal, 10)
                            .padding(.vertical, 8)
                            .background(
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .fill(useOther ? NocturnalPalette.bgHighlight : NocturnalPalette.bgElevated)
                            )
                        }
                        .buttonStyle(.plain)
                        .disabled(isSubmitting)
                        .accessibilityLabel("Other freeform answer")
                    }
                }
            }

            if prompt.allowFreeform || prompt.choices.isEmpty || useOther {
                TextField(
                    prompt.placeholder ?? "Your answer",
                    text: $answerText,
                    axis: .vertical
                )
                .lineLimit(2...5)
                .textFieldStyle(.roundedBorder)
                .focused($answerFocused)
                .disabled(isSubmitting)
                .onChange(of: answerText) { _, newValue in
                    // Editing freeform into an exact listed choice must select that choice.
                    if prompt.choices.contains(newValue) {
                        selectedChoice = newValue
                        useOther = false
                    } else if useOther || prompt.choices.isEmpty {
                        selectedChoice = nil
                    } else {
                        useOther = prompt.allowFreeform
                        selectedChoice = nil
                    }
                }
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
                .keyboardShortcut(.return, modifiers: [.command])
                .disabled(!canSend)
                .accessibilityLabel("Send answer")
                .accessibilityHint("Command-Return to send")
            }
        }
        .padding(20)
        .frame(minWidth: 360, minHeight: 240)
        .background(NocturnalPalette.bgBase)
        .onAppear {
            if prompt.choices.isEmpty {
                answerFocused = true
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Question for \(session.title)")
    }

    private func submitAnswer() {
        guard canSend else { return }
        isSubmitting = true
        Task {
            let ok = await model.answer(prompt, text: effectiveAnswer)
            if ok {
                dismiss()
            } else {
                isSubmitting = false
            }
        }
    }
}
