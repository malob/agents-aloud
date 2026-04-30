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
    // .app wrapper (Contents/Resources/ClaudeCodeVoice_ClaudeCodeVoice.bundle/)
    // because SwiftPM expects its own runtime bundle layout. Try the
    // wrapper layout first, fall back to Bundle.module for `swift run`
    // / `swift test`. The bundle name string here must match the
    // PackageName_TargetName.bundle convention SwiftPM emits.
    private static var symbolBundle: Bundle {
        let resourceBundleName = "ClaudeCodeVoice_ClaudeCodeVoice.bundle"
        if let appResourceURL = Bundle.main.resourceURL?.appendingPathComponent(resourceBundleName),
            let appResourceBundle = Bundle(url: appResourceURL)
        {
            return appResourceBundle
        }

        return Bundle.module
    }
}
