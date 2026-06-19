import SwiftUI

// Renders a TranscriptSource's custom SF Symbol at a specific point
// size. Shared between the sidebar (filter chip + per-row indicator)
// and the transcript message header so the assistant role is branded
// per-source rather than rendered as a generic "Assistant".
//
// `.brand` uses the symbol's full multicolor palette; `.adaptive`
// falls back to monochrome template rendering for places where the
// symbol is being colored externally (e.g. the selected-segment
// state in the source filter chip, where we draw a white symbol on
// the accent background).
struct SourceBrandIcon: View {
    enum Palette {
        case adaptive
        case brand
    }

    let source: TranscriptSource
    var size: CGFloat = 14
    var palette: Palette = .brand

    var body: some View {
        image
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }

    @ViewBuilder
    private var image: some View {
        switch palette {
        case .adaptive:
            Image(source.assetName, bundle: Self.symbolBundle)
                .font(.system(size: size, weight: .medium))
                .symbolRenderingMode(.monochrome)
        case .brand:
            Image(source.assetName, bundle: Self.symbolBundle)
                .font(.system(size: size, weight: .medium))
                .symbolRenderingMode(.multicolor)
        }
    }

    // SwiftPM's auto-generated `Bundle.module` accessor doesn't find
    // the resource bundle when the executable runs from our hand-built
    // .app wrapper (Contents/Resources/AgentsAloud_AgentsAloud.bundle/)
    // because SwiftPM expects its own runtime bundle layout. Try the
    // wrapper layout first, fall back to Bundle.module for `swift run`
    // / `swift test`. The bundle name string here must match the
    // PackageName_TargetName.bundle convention SwiftPM emits.
    private static var symbolBundle: Bundle {
        let resourceBundleName = "AgentsAloud_AgentsAloud.bundle"
        if let appResourceURL = Bundle.main.resourceURL?.appendingPathComponent(resourceBundleName),
            let appResourceBundle = Bundle(url: appResourceURL)
        {
            return appResourceBundle
        }

        return Bundle.module
    }
}

// Color tokens that match the dominant fill in each source's
// .symbolset glyph. Used to color the assistant title text in the
// transcript header so the chip reads as a single branded unit
// rather than an accent-blue label next to a warm/purple icon.
//
// Lives in this file (rather than alongside the TranscriptSource
// enum in Models/) because Color is a SwiftUI type and the Models
// layer is otherwise free of SwiftUI imports.
extension TranscriptSource {
    var labelColor: Color {
        switch self {
        case .claude:
            // Anthropic Crail (#D97757) — pulled from the multicolor-0:custom
            // fill in claude.symbolset/claude.svg so icon and label match.
            return Color(red: 0xD9 / 255.0, green: 0x77 / 255.0, blue: 0x57 / 255.0)
        case .codex:
            // codex.symbolset uses systemIndigoColor for its multicolor
            // layer, which maps directly to SwiftUI's Color.indigo.
            // Adaptive across light/dark mode for free.
            return .indigo
        }
    }
}
