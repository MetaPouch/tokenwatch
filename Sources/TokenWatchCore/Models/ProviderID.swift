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

    /// What this provider reads and how to produce a credential if there isn't one yet. Shown
    /// as a caption under its Settings toggle regardless of current sign-in state, and reused
    /// verbatim as the dashboard's error message when `.credentialsMissing` -- one sentence that
    /// either confirms what TokenWatch is reading or tells you exactly what to go do, since
    /// "Not signed in" alone left no next step for a first-time user.
    public var credentialSourceHint: String {
        switch self {
        case .claude: return "Reads Claude Code's local session — sign in via the Claude CLI or Claude.ai app first."
        case .codex: return "Reads ~/.codex/auth.json — run `codex login` first."
        case .cursor: return "Reads Cursor.app's local session (Safari cookie fallback) — sign into Cursor.app first."
        case .copilot: return "Reuses a sign-in from another Copilot client (VS Code, Neovim, JetBrains) — sign into one of those first."
        case .gemini: return "Reads the Gemini CLI's local session — run `gemini` and sign in with a personal Google account first."
        case .antigravity: return "Reads the Antigravity CLI's local session — sign in via that CLI first."
        case .grok: return "Reads ~/.grok/auth.json — sign in via the Grok CLI first."
        case .amp: return "Uses the amp CLI when installed and signed in, or an API key."
        case .openai, .openrouter, .zai, .kimi, .opencode: return "Needs an API key, added in Settings."
        }
    }

    /// Guidance for `.notConfigured` -- a credential exists but isn't usable as-is, which is a
    /// different problem than not having one at all. `nil` for every provider that never
    /// actually returns this case, falling back to the generic "Not configured".
    public var notConfiguredHint: String? {
        switch self {
        case .gemini:
            return "Signed in with an API key or Vertex AI, which TokenWatch doesn't read yet — run `gemini` and switch to personal Google sign-in (OAuth) instead."
        case .openai:
            return "This key can't read the Usage API — it needs Admin scope (an sk-admin-… key from platform.openai.com), not a regular project key."
        default:
            return nil
        }
    }
}
