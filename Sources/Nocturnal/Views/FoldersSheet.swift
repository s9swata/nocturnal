import AppKit
import SwiftUI

/// Local config / data roots revealed in Finder (no network, no invented paths).
struct FolderEntry: Identifiable, Hashable {
    var id: String { path }
    var title: String
    var subtitle: String
    var path: String
    var systemImage: String

    /// Existence-checked entries for the Folders sheet.
    static func resolve(appSupportPath: String?) -> [FolderEntry] {
        var items: [FolderEntry] = []
        let fm = FileManager.default
        let home = NSHomeDirectory()

        if let root = appSupportPath, fm.fileExists(atPath: root) {
            items.append(FolderEntry(
                title: "Nocturnal",
                subtitle: "App Support",
                path: root,
                systemImage: "moon.stars"
            ))
            let sessions = (root as NSString).appendingPathComponent("sessions")
            if fm.fileExists(atPath: sessions) {
                items.append(FolderEntry(
                    title: "Sessions",
                    subtitle: "Persisted sessions",
                    path: sessions,
                    systemImage: "list.bullet.rectangle"
                ))
            }
            let responses = (root as NSString).appendingPathComponent("responses")
            if fm.fileExists(atPath: responses) {
                items.append(FolderEntry(
                    title: "Responses",
                    subtitle: "Approval / answer files",
                    path: responses,
                    systemImage: "tray.full"
                ))
            }
        }

        let codex = (home as NSString).appendingPathComponent(".codex")
        if fm.fileExists(atPath: codex) {
            items.append(FolderEntry(
                title: "Codex",
                subtitle: "~/.codex",
                path: codex,
                systemImage: "terminal"
            ))
        }

        let claude = (home as NSString).appendingPathComponent(".claude")
        if fm.fileExists(atPath: claude) {
            items.append(FolderEntry(
                title: "Claude",
                subtitle: "~/.claude",
                path: claude,
                systemImage: "bubble.left.and.bubble.right"
            ))
        }

        let opencode = (home as NSString).appendingPathComponent(".config/opencode")
        if fm.fileExists(atPath: opencode) {
            items.append(FolderEntry(
                title: "OpenCode",
                subtitle: "~/.config/opencode",
                path: opencode,
                systemImage: "chevron.left.forwardslash.chevron.right"
            ))
        }

        return items
    }
}

struct FoldersSheet: View {
    @Bindable var model: AppModel
    @Environment(\.dismiss) private var dismiss

    private var entries: [FolderEntry] { model.folderEntries }

    private let columns = [
        GridItem(.adaptive(minimum: 100), spacing: 12),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Folders")
                    .font(.headline)
                    .foregroundStyle(NocturnalPalette.fgPrimary)
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }

            Text("Local roots only. Reveal opens Finder.")
                .font(.caption)
                .foregroundStyle(NocturnalPalette.fgSecondary)

            if entries.isEmpty {
                Text("No known folders yet. App Support appears after first launch.")
                    .font(.caption)
                    .foregroundStyle(NocturnalPalette.fgSecondary)
                    .frame(maxWidth: .infinity, minHeight: 80, alignment: .center)
            } else {
                LazyVGrid(columns: columns, spacing: 12) {
                    ForEach(entries) { entry in
                        Button {
                            model.revealFolder(entry)
                        } label: {
                            VStack(spacing: 8) {
                                Image(systemName: entry.systemImage)
                                    .font(.title2)
                                    .foregroundStyle(NocturnalPalette.fgSecondary)
                                    .frame(width: 44, height: 44)
                                    .background(
                                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                                            .fill(NocturnalPalette.bgElevated)
                                    )
                                Text(entry.title)
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(NocturnalPalette.fgPrimary)
                                    .lineLimit(1)
                                Text(entry.subtitle)
                                    .font(.caption2)
                                    .foregroundStyle(NocturnalPalette.fgSecondary)
                                    .lineLimit(1)
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 8)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .help(entry.path)
                        .accessibilityLabel("Reveal \(entry.title)")
                        .accessibilityHint(entry.path)
                    }
                }
            }
        }
        .padding(20)
        .frame(minWidth: 360, minHeight: 220)
        .background(NocturnalPalette.bgBase)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Local folders")
    }
}
