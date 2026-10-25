import Foundation
import Testing
@testable import SiriPlusCore

@Suite
struct UsageParserTests {
    private let moscow = TimeZone(identifier: "Europe/Moscow")!

    private func date(_ year: Int, _ month: Int, _ day: Int, _ hour: Int, _ minute: Int = 0) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = moscow
        return calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute))!
    }

    @Test func readsClaudeUsageReport() {
        let report = """
        You are currently using your subscription to power your Claude Code usage

        Current session: 9% used · resets Oct 26 at 2:50am (Europe/Moscow)
        Current week (all models): 6% used · resets Nov 1 at 9pm (Europe/Moscow)
        Current week (Opus): 40% used · resets Nov 1 at 9pm (Europe/Moscow)

        Last 24h · 437 requests · 2 sessions
        """
        let now = date(2026, 10, 25, 22)
        let limits = UsageParser.claude(report: report, now: now)
        #expect(limits.map(\.kind) == [.session, .weekly, .other])
        #expect(limits[0].remainingPercent == 91)
        #expect(limits[0].resetsAt == date(2026, 10, 26, 2, 50))
        #expect(limits[1].resetsAt == date(2026, 11, 1, 21))
        #expect(limits[2].label == "Week (Opus)")
        #expect(AccountUsage(limits: limits, fetchedAt: now).compactText == "5h 91% · Week 94%")
    }

    @Test func claudeResetRollsIntoTheNextYearAndDay() {
        // A date in January read in December belongs to the next year.
        #expect(UsageParser.claudeReset("Jan 2 at 9am (Europe/Moscow)", now: date(2026, 12, 30, 12)) == date(2027, 1, 2, 9))
        // A time without a date that has already passed today is tomorrow.
        #expect(UsageParser.claudeReset("1am (Europe/Moscow)", now: date(2026, 10, 25, 22)) == date(2026, 10, 26, 1))
        #expect(UsageParser.claudeReset("soon", now: date(2026, 10, 25, 22)) == nil)
    }

    @Test func unreadableResetKeepsTheText() {
        let limits = UsageParser.claude(report: "Current session: 50% used · resets whenever", now: Date())
        #expect(limits.first?.resetsAt == nil)
        #expect(limits.first?.resetsText == "whenever")
    }

    @Test func readsChatGPTUsage() throws {
        let json = #"""
        {"plan_type":"plus",
         "rate_limit":{"primary_window":{"used_percent":36,"limit_window_seconds":18000,"reset_after_seconds":3600},
                       "secondary_window":{"used_percent":18,"limit_window_seconds":604800,"reset_at":1793566800}},
         "additional_rate_limits":[{"limit_name":"Codex extra","rate_limit":{"primary_window":{"used_percent":50,"limit_window_seconds":86400}}}]}
        """#
        let now = Date(timeIntervalSince1970: 1_793_000_000)
        let usage = try UsageParser.chatGPT(Data(json.utf8), now: now)
        #expect(usage.plan == "plus")
        #expect(usage.limits.map(\.kind) == [.session, .weekly, .other])
        #expect(usage.limits[0].remainingPercent == 64)
        #expect(usage.limits[0].resetsAt == now.addingTimeInterval(3600))
        #expect(usage.limits[1].resetsAt == Date(timeIntervalSince1970: 1_793_566_800))
        #expect(usage.limits[2].label == "Codex extra · Day")
        #expect(usage.compactText == "5h 64% · Week 82%")
    }
}

@Suite @MainActor
struct UsageModelTests {
    private struct Failure: LocalizedError { var errorDescription: String? { "offline" } }

    @Test func keepsLastNumbersOnErrorAndClearsSignedOutAccounts() async {
        let sample = AccountUsage(plan: "pro", limits: [UsageLimit(kind: .session, label: "5 hours", usedPercent: 20, resetsAt: nil)], fetchedAt: Date())
        let failing = Flag()
        let model = UsageModel(
            fetchClaude: { if failing.value { throw Failure() }; return sample },
            fetchChatGPT: { throw Failure() }
        )
        await model.refresh(claude: true, chatGPT: true)
        #expect(model.claude == sample)
        #expect(model.chatGPTError == "offline")
        #expect(model.usage(for: ModelSelection(provider: .claude, claudeAuth: .account)) == sample)
        #expect(model.usage(for: ModelSelection(provider: .claude, claudeAuth: .apiKey)) == nil)

        failing.value = true
        await model.refresh(claude: true, chatGPT: false)
        #expect(model.claude == sample)
        #expect(model.claudeError == "offline")
        #expect(model.chatGPTError == nil)

        await model.refresh(claude: false, chatGPT: false)
        #expect(model.claude == nil)
    }
}

private final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var stored = false
    var value: Bool {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }
}
