import Foundation

/// Stable identifier for every usage provider TokenWatch knows how to poll.
public enum ProviderID: String, CaseIterable, Codable, Sendable, Identifiable {
    case claude
    case codex
    case openai
    case gemini
    case antigravity
    case cursor
    case copilot
    case openrouter
    case zai
    case kimi
    case amp
    case grok
    case opencode

    public var id: String { rawValue }

    /// Human-readable name for menus and settings.
    public var displayName: String {
        switch self {
        case .claude: return "Claude"
        case .codex: return "Codex"
        case .openai: return "OpenAI"
        case .gemini: return "Gemini"
        case .antigravity: return "Antigravity"
        case .cursor: return "Cursor"
        case .copilot: return "GitHub Copilot"
        case .openrouter: return "OpenRouter"
        case .zai: return "z.ai"
        case .kimi: return "Kimi"
        case .amp: return "Amp"
        case .grok: return "Grok"
        case .opencode: return "OpenCode"
        }
    }

    /// Filename (without extension) of this provider's real logo, bundled as an SVG under
    /// `Sources/TokenWatch/Icons/` (sourced from github.com/lobehub/lobe-icons, MIT licensed --
    /// see that directory's `NOTICE.md`). TokenWatchCore stays UI-framework-agnostic: this is
    /// just the resource name, not an `NSImage`/`Image` -- the App layer loads and renders it.
    public var iconResourceName: String { rawValue }

    /// `true` for providers whose bundled icon is a single-color `fill="currentColor"` mark
    /// (the brand itself is monochrome, not TokenWatch's choice) -- the App layer should tint
    /// these to match the surrounding text rather than leaving them a fixed black glyph.
    /// `false` for icons whose real logo has multiple colors baked into the asset already.
    public var hasMonochromeIcon: Bool {
        switch self {
        case .openai, .cursor, .zai, .grok, .opencode: return true
        case .claude, .codex, .gemini, .antigravity, .copilot, .openrouter, .kimi, .amp: return false
        }
    }
}
