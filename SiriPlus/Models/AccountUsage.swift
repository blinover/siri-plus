import Foundation

/// One subscription limit window: how much of it is used and when it starts over.
struct UsageLimit: Identifiable, Equatable, Sendable {
    enum Kind: Int, Comparable, Sendable {
        case session
        case weekly
        case other

        static func < (lhs: Kind, rhs: Kind) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    let kind: Kind
    let label: String
    let usedPercent: Double
    let resetsAt: Date?
    /// The provider's own wording, when the date could not be read.
    var resetsText: String?

    var id: String { label }
    var remainingPercent: Double { max(0, 100 - usedPercent) }
}

/// Subscription limits of the signed-in Claude or ChatGPT account.
struct AccountUsage: Equatable, Sendable {
    var plan: String?
    var limits: [UsageLimit]
    var fetchedAt: Date

    /// "5h 94% · Week 95%": what is left of the main windows.
    var compactText: String? {
        let main = limits.filter { $0.kind != .other }
        guard !main.isEmpty else { return nil }
        return main.map { "\($0.shortLabel) \(Int($0.remainingPercent.rounded()))%" }.joined(separator: " · ")
    }
}

extension UsageLimit {
    var shortLabel: String {
        switch kind {
        case .session: String(localized: "5h")
        case .weekly: String(localized: "Week")
        case .other: label
        }
    }
}

enum UsageParser {
    static func claude(report: String, now: Date = Date()) -> [UsageLimit] {
        // A limit line of `claude -p /usage`, e.g. "Current session: 6% used · resets Oct 26 at 2:50am (Europe/Moscow)".
        let claudeLine = #/^\s*(Current [^:]+):\s*(\d+(?:\.\d+)?)%\s*used(?:\s*·\s*resets\s+(.+?))?\s*$/#
        return report.split(whereSeparator: \.isNewline).compactMap { line -> UsageLimit? in
            guard let match = try? claudeLine.wholeMatch(in: String(line)) else { return nil }
            let name = String(match.1)
            let resets = match.3.map(String.init)
            let (kind, label) = claudeLabel(name)
            let date = resets.flatMap { claudeReset($0, now: now) }
            return UsageLimit(
                kind: kind,
                label: label,
                usedPercent: min(100, max(0, Double(match.2) ?? 0)),
                resetsAt: date,
                resetsText: date == nil ? resets : nil
            )
        }
        .sorted { $0.kind < $1.kind }
    }

    private static func claudeLabel(_ name: String) -> (UsageLimit.Kind, String) {
        let lowered = name.lowercased()
        if lowered.contains("session") { return (.session, String(localized: "5 hours")) }
        if lowered.contains("week") {
            // "Current week (Opus)" limits one model family; "(all models)" is the general weekly limit.
            if let range = name.range(of: #"\(([^)]+)\)"#, options: .regularExpression) {
                let inner = name[range].dropFirst().dropLast()
                if !inner.lowercased().contains("all models") {
                    return (.other, String(localized: "Week (\(String(inner)))"))
                }
            }
            return (.weekly, String(localized: "Week"))
        }
        return (.other, name.replacingOccurrences(of: "Current ", with: ""))
    }

    static func claudeReset(_ text: String, now: Date = Date()) -> Date? {
        // "Oct 26 at 2:50am (Europe/Moscow)", "Nov 1 at 9pm (Europe/Moscow)" or "2:50am (Europe/Moscow)".
        let claudeDate = #/^(?:([A-Z][a-z]{2}) (\d{1,2}) at )?(\d{1,2})(?::(\d{2}))?\s*(am|pm)(?:\s*\(([^)]+)\))?/#
        guard let match = try? claudeDate.firstMatch(in: text) else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = match.6.flatMap { TimeZone(identifier: String($0)) } ?? .current
        var hour = (Int(match.3) ?? 0) % 12
        if match.5 == "pm" { hour += 12 }
        var components = calendar.dateComponents([.year, .month, .day], from: now)
        components.hour = hour
        components.minute = match.4.flatMap { Int($0) } ?? 0
        if let monthName = match.1, let day = match.2 {
            let months = ["jan", "feb", "mar", "apr", "may", "jun", "jul", "aug", "sep", "oct", "nov", "dec"]
            guard let month = months.firstIndex(of: monthName.lowercased()) else { return nil }
            components.month = month + 1
            components.day = Int(day)
        }
        guard var date = calendar.date(from: components) else { return nil }
        // The report never names a year, and a time without a date is the next one coming.
        while date < now.addingTimeInterval(-60) {
            guard let next = calendar.date(byAdding: match.1 == nil ? .day : .year, value: 1, to: date) else { break }
            date = next
        }
        return date
    }

    /// The `wham/usage` payload of a ChatGPT account.
    static func chatGPT(_ data: Data, now: Date = Date()) throws -> AccountUsage {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw OpenAIError.failed(String(localized: "Could not read the ChatGPT usage limits."))
        }
        var limits: [UsageLimit] = []
        if let main = (root["rate_limit"] ?? root["rate_limits"]) as? [String: Any] {
            limits += windows(of: main, name: nil, now: now)
        }
        for extra in root["additional_rate_limits"] as? [[String: Any]] ?? [] {
            let name = extra["limit_name"] as? String
            if let limit = extra["rate_limit"] as? [String: Any] {
                limits += windows(of: limit, name: name, now: now).map { window in
                    UsageLimit(kind: .other, label: window.label, usedPercent: window.usedPercent, resetsAt: window.resetsAt)
                }
            }
        }
        let plan = root["plan_type"] as? String ?? (root["plan"] as? [String: Any])?["type"] as? String
        return AccountUsage(plan: plan, limits: limits.sorted { $0.kind < $1.kind }, fetchedAt: now)
    }

    private static func windows(of limit: [String: Any], name: String?, now: Date) -> [UsageLimit] {
        ["primary_window", "secondary_window"].compactMap { key -> UsageLimit? in
            guard let window = limit[key] as? [String: Any],
                  let used = number(window["used_percent"]) else { return nil }
            let seconds = number(window["limit_window_seconds"]) ?? 0
            let kind: UsageLimit.Kind = name != nil ? .other : seconds == 18_000 ? .session : seconds == 604_800 ? .weekly : .other
            var label: String
            switch seconds {
            case 18_000: label = String(localized: "5 hours")
            case 86_400: label = String(localized: "Day")
            case 604_800: label = String(localized: "Week")
            case let value where value > 0: label = String(localized: "\(Int(value / 3600)) hours")
            default: label = key == "primary_window" ? String(localized: "Main") : String(localized: "Secondary")
            }
            if let name { label = "\(name) · \(label)" }
            var reset: Date?
            if let after = number(window["reset_after_seconds"]) {
                reset = now.addingTimeInterval(after)
            } else if let at = number(window["reset_at"]) {
                reset = Date(timeIntervalSince1970: at > 10_000_000_000 ? at / 1000 : at)
            }
            return UsageLimit(kind: kind, label: label, usedPercent: min(100, max(0, used)), resetsAt: reset)
        }
    }

    private static func number(_ value: Any?) -> Double? {
        (value as? NSNumber)?.doubleValue ?? (value as? String).flatMap(Double.init)
    }
}

extension UsageLimit {
    /// "resets in 3 hours (02:50)", or the date for windows further away.
    func resetDescription(now: Date = Date()) -> String? {
        guard let resetsAt else { return resetsText.map { String(localized: "resets \($0)") } }
        let relative = resetsAt.formatted(.relative(presentation: .named))
        let when = resetsAt.timeIntervalSince(now) < 24 * 3600
            ? resetsAt.formatted(date: .omitted, time: .shortened)
            : resetsAt.formatted(.dateTime.day().month().hour().minute())
        return String(localized: "resets \(relative) (\(when))")
    }

    /// "5 hours: 91% left · resets in 3 hours (02:50)" for menus and tooltips.
    var summary: String {
        let left = String(localized: "\(label): \(Int(remainingPercent.rounded()))% left")
        return [left, resetDescription()].compactMap { $0 }.joined(separator: " · ")
    }
}
