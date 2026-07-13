import AppKit
import SwiftUI
import NocturnalCore

/// Sets the process app icon for `swift run` / unpackaged launches.
/// Packaged builds also use `CFBundleIconFile` (Icon.icns) from `package_app.sh`.
final class NocturnalAppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        if let icon = BrandAssets.appIconNSImage() {
            NSApplication.shared.applicationIconImage = icon
        }
    }
}

@main
struct NocturnalApp: App {
    @NSApplicationDelegateAdaptor(NocturnalAppDelegate.self) private var appDelegate
    @State private var model = AppModel()

    var body: some Scene {
        // Companion app: menu bar is the primary surface. Floating pill is AppKit-hosted.
        // Template owl mark adapts to light/dark menu bars without a square background.
        MenuBarExtra {
            MenuBarView(model: model)
        } label: {
            menuBarLabel
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView(model: model)
        }

        // Lightweight status window for development / non-LSUIElement runs.
        Window("Nocturnal", id: "main") {
            RootView(model: model)
                .frame(minWidth: 360, minHeight: 320)
        }
        .defaultSize(width: 420, height: 520)
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandGroup(after: .appInfo) {
                Button(model.isOverlayExpanded ? "Collapse Pill Panel" : "Expand Pill Panel") {
                    model.toggleOverlayExpanded()
                }
                .keyboardShortcut("p", modifiers: [.command, .shift])
                .disabled(!model.settings.showFloatingPill)

                Divider()

                Button("Copy Setup Command") {
                    model.copySetupCommand()
                }
                .keyboardShortcut("c", modifiers: [.command, .shift])
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

    @ViewBuilder
    private var menuBarLabel: some View {
        if let image = BrandAssets.owlMarkNSImage(size: 16) {
            // Template treatment: system tints for light/dark menu bar; no square fill.
            Image(nsImage: image)
                .renderingMode(.template)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 16, height: 16)
                .accessibilityLabel("Nocturnal")
        } else {
            Image(systemName: "circle.grid.cross.fill")
                .symbolRenderingMode(.monochrome)
                .accessibilityLabel("Nocturnal")
        }
    }
}
