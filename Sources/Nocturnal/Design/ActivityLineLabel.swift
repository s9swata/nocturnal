import SwiftUI
import NocturnalCore

/// Two-tone activity copy: verb in primary (white), detail in secondary (grey).
///
/// Example: **Ran** `git status -sb`  ·  **Searched** `nocturnal hooks`
struct ActivityLineLabel: View {
    var line: HumanizedActivityLine
    var font: Font = .caption
    var verbColor: Color = NocturnalPalette.fgPrimary
    var detailColor: Color = NocturnalPalette.fgSecondary

    var body: some View {
        // Single Text + nested Text keeps baseline alignment and truncation.
        (
            Text(line.verb)
                .foregroundStyle(verbColor)
            + (line.detail.map { detail in
                Text(" \(detail)")
                    .foregroundStyle(detailColor)
            } ?? Text(""))
        )
        .font(font)
        .accessibilityLabel(line.fullLine)
    }
}
