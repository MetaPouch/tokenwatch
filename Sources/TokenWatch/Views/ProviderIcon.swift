import SwiftUI
import AppKit
import TokenWatchCore

/// Renders a provider's real logo, bundled as SVG under `Sources/TokenWatch/Icons/` (see that
/// directory's `NOTICE.md` for source and license). macOS decodes SVG natively via `NSImage`, so
/// these ship as plain resource files -- no asset catalog, no rasterized PNGs to maintain per
/// scale factor.
///
/// Resource lookup is intentionally not just `Bundle.module`: SwiftPM's generated accessor only
/// ever checks the .app's own top level or the raw build directory, and content outside
/// `Contents/` fails codesign verification ("code has no resources but signature indicates they
/// must be present"). `scripts/build-app.sh` copies the icons to `Contents/Resources/Icons/`
/// instead, which this checks first; `Bundle.module` remains the fallback for `swift run`/`swift
/// test`, where that concern doesn't apply.
struct ProviderIcon: View {
    let provider: ProviderID
    var size: CGFloat = 16

    var body: some View {
        Group {
            if let image = Self.loadedImages[provider.iconResourceName] {
                Image(nsImage: image)
                    .resizable()
            } else {
                // Bundling failed to find the resource (shouldn't happen in a normal build) --
                // fall back to a generic placeholder rather than an empty space.
                Image(systemName: "questionmark.circle")
                    .resizable()
                    .foregroundStyle(.secondary)
            }
        }
        .scaledToFit()
        .frame(width: size, height: size)
    }

    /// Every provider's SVG loaded once and cached -- thirteen small vector files, no reason to
    /// re-decode per render. Monochrome brand marks (`fill="currentColor"` in the source SVG)
    /// are marked as template images so they pick up the surrounding text color instead of
    /// rendering as a fixed black glyph; multi-color marks render with their real, baked-in
    /// brand colors untouched.
    private static let loadedImages: [String: NSImage] = {
        var result: [String: NSImage] = [:]
        for provider in ProviderID.allCases {
            guard let url = resourceURL(for: provider), let image = NSImage(contentsOf: url) else { continue }
            // Deliberately not overriding `image.size`: these SVGs report no intrinsic size of
            // their own (relying on the source's CSS-relative `1em`/viewBox), and forcing one
            // confuses SwiftUI's `.resizable().frame()` sizing -- the icon renders at multiples
            // of the assigned size instead of the requested frame (verified via offscreen
            // render; empirically, leaving the native near-zero reported size alone is what
            // makes `.frame(width:height:)` actually take effect at render time).
            image.isTemplate = provider.hasMonochromeIcon
            result[provider.iconResourceName] = image
        }
        return result
    }()

    /// Tries `.svg` then `.png` -- CoreSVG (macOS's native SVG decoder, used by `NSImage`)
    /// doesn't fully support every construct Lobe Icons' SVGs use; Gemini's four layered
    /// `linearGradient` fills silently fail to render (logs a CoreSVG error, draws almost
    /// nothing), so that one ships as a PNG raster of the same source icon instead. Extension
    /// order lets any future icon drop in a PNG the same way without code changes.
    private static func resourceURL(for provider: ProviderID) -> URL? {
        let name = provider.iconResourceName
        for ext in ["svg", "png"] {
            if let packaged = Bundle.main.resourceURL?.appendingPathComponent("Icons/\(name).\(ext)"),
               FileManager.default.fileExists(atPath: packaged.path) {
                return packaged
            }
            // `resources: [.copy("Icons")]` in Package.swift preserves "Icons" as a real
            // subdirectory inside the generated bundle rather than flattening it to the
            // bundle's top level, so the lookup must say so explicitly -- omitting
            // `subdirectory:` silently finds nothing even though the file is right there.
            //
            // SwiftPM's generated `Bundle.module` accessor calls `Swift.fatalError` -- an
            // unconditional, uncatchable process abort -- if it can't find its `.bundle` wrapper
            // either next to the running binary or at the exact path it was built at on this
            // machine. A packaged `.app` never ships that wrapper (see this type's doc comment),
            // so merely *referencing* `Bundle.module` here -- even just to ask it for a resource
            // that happens to be missing -- would crash the entire app over one bad icon file
            // instead of falling back to the placeholder glyph `ProviderIcon.body` already
            // handles. Only take this path outside a real `.app` bundle (`swift run`/`swift
            // test`), where `Bundle.module` is expected to actually resolve.
            guard Bundle.main.bundlePath.hasSuffix(".app") else {
                if let moduleURL = Bundle.module.url(forResource: name, withExtension: ext, subdirectory: "Icons") {
                    return moduleURL
                }
                continue
            }
        }
        return nil
    }
}
