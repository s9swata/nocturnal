import SwiftUI
import NocturnalCore

@main
struct NocturnalApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        // Companion app: menu bar is the primary surface. Floating pill is AppKit-hosted.
        MenuBarExtra("Nocturnal", systemImage: "moon.stars.fill") {
            MenuBarView(model: model)
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView(model: model)
        }

        // Lightweight status window for development / non-LSUIElement runs.
        Window("Nocturnal", id: "main") {
            RootView(model: model)
                .frame(minWidth: 320, minHeight: 280)
        }
        .defaultSize(width: 380, height: 480)
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandGroup(after: .appInfo) {
                Button(model.settings.demoMode ? "Exit Demo Mode" : "Enter Demo Mode") {
                    Task { await model.toggleDemoMode() }
                }
                .keyboardShortcut("d", modifiers: [.command, .shift])

                Button("Reload Demo Fixtures") {
                    Task { await model.reloadDemoFixtures() }
                }
                .keyboardShortcut("r", modifiers: [.command, .shift])
                .disabled(!model.settings.demoMode)

                Divider()

                Button(model.isOverlayExpanded ? "Collapse Pill Panel" : "Expand Pill Panel") {
                    model.toggleOverlayExpanded()
                }
                .keyboardShortcut("p", modifiers: [.command, .shift])
                .disabled(!model.settings.showFloatingPill)
            }
            CommandMenu("Sessions") {
                Button("Select Next Session") {
                    model.selectNextSession(delta: 1)
                }
                .keyboardShortcut("j", modifiers: [.command])

                Button("Select Previous Session") {
                    model.selectNextSession(delta: -1)
                }
                .keyboardShortcut("k", modifiers: [.command])

                Divider()

                Button("Approve Selected") {
                    Task { await model.approveSelected(approved: true) }
                }
                .keyboardShortcut("a", modifiers: [.command, .option])

                Button("Deny Selected") {
                    Task { await model.approveSelected(approved: false) }
                }
                .keyboardShortcut("d", modifiers: [.command, .option])
            }
        }
    }
}
