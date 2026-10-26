import Foundation

/// A model the user can choose, as the provider lists it for their account or key.
struct ModelOption: Identifiable, Hashable, Sendable {
    let id: String
    let title: String
    var detail: String?
    /// Effort levels the model accepts: nil when unknown, empty when it takes none.
    var efforts: [String]?

    /// Claude Code's aliases, used until it lists the account's models; each follows the newest model of its family.
    static let claudeCodeDefaults: [ModelOption] = [
        .init(id: "default", title: String(localized: "Claude Code default")),
        .init(id: "opus", title: "Opus"),
        .init(id: "sonnet", title: "Sonnet"),
        .init(id: "haiku", title: "Haiku"),
    ]

    /// Models for an Anthropic API key, used until the Models API answers.
    static let claudeAPIDefaults: [ModelOption] = [
        .init(id: "claude-opus-5-5", title: "Claude Opus 5.5", efforts: ModelEffort.claudeLevels),
        .init(id: "claude-fable-5-1", title: "Claude Fable 5.1", efforts: ModelEffort.claudeLevels),
        .init(id: "claude-sonnet-5-5", title: "Claude Sonnet 5.5", efforts: ModelEffort.claudeLevels),
        .init(id: "claude-haiku-5-5", title: "Claude Haiku 5.5", efforts: ModelEffort.claudeLevels),
    ]

    /// Models offered for an OpenAI API key. A ChatGPT account lists its own models.
    static let openAIAPIModels: [ModelOption] = [
        .init(id: "gpt-6-astra", title: String(localized: "GPT-6 Astra — most capable"), efforts: ModelEffort.openAIAPILevels),
        .init(id: "gpt-6.1-sol", title: String(localized: "GPT-6.1 Sol — balanced"), efforts: ModelEffort.openAIAPILevels),
        .init(id: "gpt-6-luna", title: String(localized: "GPT-6 Luna — fastest and cheapest"), efforts: ModelEffort.openAIAPILevels),
    ]

    static let openAIAPIDefault = openAIAPIModels[1]

    /// Claude API models that accept the server-side refusal fallback ("default" form).
    static let claudeFallbackModels: Set<String> = ["claude-fable-5-1", "claude-opus-5-5", "claude-opus-5", "claude-sonnet-5-5"]

    /// The Claude Code alias for a Claude API model ID saved by Siri+ 0.3 and earlier.
    static func claudeCodeAlias(forLegacy id: String) -> String {
        ["opus", "sonnet", "haiku", "fable"].first { id.contains($0) } ?? "opus"
    }
}

/// How long a model thinks before answering. "auto" lets Siri+ choose per request.
enum ModelEffort {
    static let automatic = "auto"
    /// Known levels from the lightest to the deepest; providers accept different subsets.
    static let order = ["none", "minimal", "low", "medium", "high", "xhigh", "max", "ultra"]
    static let claudeLevels = ["low", "medium", "high", "xhigh", "max"]
    static let openAIAPILevels = ["low", "medium", "high"]

    static func title(_ level: String) -> String {
        switch level {
        case automatic: String(localized: "Automatic")
        case "none": String(localized: "No thinking")
        case "minimal": String(localized: "Minimal")
        case "low": String(localized: "Low")
        case "medium": String(localized: "Medium")
        case "high": String(localized: "High")
        case "xhigh": String(localized: "Extra high")
        case "max": String(localized: "Maximum")
        case "ultra": String(localized: "Ultra")
        default: level.capitalized
        }
    }

    /// The level to send, or nil when the model takes none.
    /// - Parameters:
    ///   - chosen: the level picked in Settings, or `automatic`.
    ///   - preferred: the level Siri+ picks for this kind of request.
    ///   - isLive: live hints must arrive within seconds, so they keep `preferred` whatever is chosen.
    ///   - supported: the model's levels; when unknown, the level is sent as is.
    static func resolve(chosen: String, preferred: String, isLive: Bool, supported: [String]?) -> String? {
        let target = isLive || chosen == automatic ? preferred : chosen
        guard let supported else { return target }
        if supported.contains(target) { return target }
        // The nearest level the model accepts; on a tie, the lighter one.
        guard let rank = order.firstIndex(of: target) else { return supported.first }
        return supported
            .compactMap { level in order.firstIndex(of: level).map { (level, abs($0 - rank), $0) } }
            .min { ($0.1, $0.2) < ($1.1, $1.2) }?.0 ?? supported.first
    }
}
