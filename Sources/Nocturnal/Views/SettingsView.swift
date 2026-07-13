import AppKit
import SwiftUI
import NocturnalCore

struct SettingsView: View {
    @Bindable var model: AppModel
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion

    var body: some View {
        TabView {
            generalPane
                .tabItem { Label("General", systemImage: "slider.horizontal.3") }
            hooksPane
                .tabItem { Label("Hooks", systemImage: "link") }
            aboutPane
                .tabItem { Label("About", systemImage: "moon.stars") }
        }
        .frame(minWidth: 420, minHeight: 360)
        .tint(NocturnalPalette.accentAttention)
    }

    // MARK: - General

    private var generalPane: some View {
        Form {
            Section {
                Toggle("Reduce motion", isOn: reduceMotionBinding)
                    .help("Prefer cross-fades and instant layout changes. Also respects system Reduce Motion.")
                Toggle("Sound", isOn: soundBinding)
                    .help("Soft attention sound when a session needs approval or input. Off by default.")
            } header: {
                Text("Quiet")
            } footer: {
                if systemReduceMotion {
                    Text("System Reduce Motion is on; animations stay minimal regardless of the toggle.")
                        .font(.caption)
                }
            }

            Section("Sessions") {
                Toggle("Demo mode", isOn: demoBinding)
                    .help("Load deterministic fixtures instead of the live hook socket.")
                Toggle("Floating pill", isOn: pillBinding)
                    .help("Show a non-activating pill at the top of the screen.")
                Stepper(value: maxSessionsBinding, in: 3...40) {
                    Text("Max visible sessions: \(model.settings.maxVisibleSessions)")
                }
            }

            Section("Status") {
                LabeledContent("Mode") {
                    Text(model.settings.demoMode ? "Demo" : (model.isSocketRunning ? "Live" : "Idle"))
                        .foregroundStyle(.secondary)
                }
                LabeledContent("Attention") {
                    Text("\(model.attentionCount)")
                        .foregroundStyle(
                            model.attentionCount > 0
                                ? NocturnalPalette.accentAttention
                                : .secondary
                        )
                }
                LabeledContent("Status") {
                    Text(model.statusMessage)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
        }
        .formStyle(.grouped)
        .padding()
        .accessibilityLabel("General settings")
    }

    // MARK: - Hooks / diagnostics

    private var hooksPane: some View {
        Form {
            Section {
                LabeledContent("Socket") {
                    Text(model.socketPathDisplay)
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                        .foregroundStyle(.secondary)
                }
                LabeledContent("App Support") {
                    Text(model.appSupportPathDisplay)
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                        .foregroundStyle(.secondary)
                }

                HStack {
                    Button("Copy socket path") {
                        copyToPasteboard(model.socketPathDisplay)
                    }
                    Button("Reveal App Support") {
                        revealInFinder(model.appSupportPathDisplay)
                    }
                }
            } header: {
                Text("Local paths")
            } footer: {
                Text("Override with NOCTURNAL_SOCKET or NOCTURNAL_APP_SUPPORT for simulation. No cloud endpoints.")
                    .font(.caption)
            }

            Section("Hook setup") {
                Text("Install fail-open hooks so Codex and Claude Code forward events to Nocturnal. If Nocturnal is down, agents keep working.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                VStack(alignment: .leading, spacing: 8) {
                    commandRow(
                        title: "Install (all products)",
                        command: "nocturnal-setup install --product all"
                    )
                    commandRow(
                        title: "Status",
                        command: "nocturnal-setup status"
                    )
                    commandRow(
                        title: "Uninstall",
                        command: "nocturnal-setup uninstall --product all"
                    )
                    commandRow(
                        title: "Dry-run native merge",
                        command: "nocturnal-setup install --mode merge-native --dry-run"
                    )
                }
            }

            Section("Forwarder") {
                Text("The hook forwarder always exits 0. Point agent hooks at nocturnal-hook-forwarder; it writes NDJSON to the socket above.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                commandRow(
                    title: "Help",
                    command: "nocturnal-hook-forwarder --help"
                )
            }
        }
        .formStyle(.grouped)
        .padding()
        .accessibilityLabel("Hook setup and paths")
    }

    // MARK: - About

    private var aboutPane: some View {
        Form {
            Section {
                HStack(spacing: 12) {
                    Image(systemName: "moon.stars.fill")
                        .font(.largeTitle)
                        .symbolRenderingMode(.hierarchical)
                        .foregroundStyle(NocturnalPalette.fgSecondary)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Nocturnal")
                            .font(.title2.weight(.semibold))
                        Text("Local companion for coding agents")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 4)

                LabeledContent("App core", value: NocturnalCore.version)
                LabeledContent("Event schema", value: "v\(NocturnalCore.eventSchemaVersion)")
            }

            Section("Privacy") {
                Text("Local-first. No accounts, no trials, no licenses, no telemetry, and no cloud backends. Session data stays under Application Support on this Mac.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section("Brand") {
                Text("Quiet nocturnal · native · precise. Warm dark surfaces, calm copy, no neon or urgency theater.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding()
        .accessibilityLabel("About Nocturnal")
    }

    // MARK: - Helpers

    private func commandRow(title: String, command: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.subheadline.weight(.medium))
            HStack(alignment: .firstTextBaseline) {
                Text(command)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .lineLimit(2)
                Spacer(minLength: 8)
                Button("Copy") {
                    copyToPasteboard(command)
                }
                .buttonStyle(.borderless)
                .font(.caption)
                .accessibilityLabel("Copy \(title) command")
            }
            .padding(8)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color(nsColor: .controlBackgroundColor))
            )
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(title): \(command)")
    }

    private func copyToPasteboard(_ string: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(string, forType: .string)
        model.noteStatus("Copied to clipboard")
    }

    private func revealInFinder(_ path: String) {
        let url = URL(fileURLWithPath: path)
        if FileManager.default.fileExists(atPath: path) {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } else {
            NSWorkspace.shared.open(url.deletingLastPathComponent())
        }
    }

    // MARK: - Bindings

    private var reduceMotionBinding: Binding<Bool> {
        Binding(
            get: { model.settings.reduceMotion },
            set: { value in
                Task { await model.updateSettings { $0.reduceMotion = value } }
            }
        )
    }

    private var soundBinding: Binding<Bool> {
        Binding(
            get: { model.settings.soundEnabled },
            set: { value in
                Task { await model.updateSettings { $0.soundEnabled = value } }
            }
        )
    }

    private var demoBinding: Binding<Bool> {
        Binding(
            get: { model.settings.demoMode },
            set: { _ in
                Task { await model.toggleDemoMode() }
            }
        )
    }

    private var pillBinding: Binding<Bool> {
        Binding(
            get: { model.settings.showFloatingPill },
            set: { value in
                Task { await model.updateSettings { $0.showFloatingPill = value } }
            }
        )
    }

    private var maxSessionsBinding: Binding<Int> {
        Binding(
            get: { model.settings.maxVisibleSessions },
            set: { value in
                Task { await model.updateSettings { $0.maxVisibleSessions = value } }
            }
        )
    }
}
