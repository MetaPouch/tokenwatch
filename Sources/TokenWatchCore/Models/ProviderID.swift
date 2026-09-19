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

    /// SF Symbol for the provider picker. Deliberately generic system glyphs, not stylized
    /// lookalikes of any provider's real logo -- the name label next to it is the actual
    /// identifier, this is just a scannable accent.
    public var symbolName: String {
        switch self {
        case .claude: return "message.fill"
        case .codex: return "chevron.left.forwardslash.chevron.right"
        case .openai: return "cpu"
        case .gemini: return "sparkles"
        case .antigravity: return "arrow.up.circle.fill"
        case .cursor: return "cursorarrow.rays"
        case .copilot: return "airplane"
        case .openrouter: return "arrow.triangle.branch"
        case .zai: return "bolt.fill"
        case .kimi: return "moon.stars.fill"
        case .amp: return "waveform"
        case .grok: return "eye.fill"
        case .opencode: return "terminal.fill"
        }
    }
}
