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
}
