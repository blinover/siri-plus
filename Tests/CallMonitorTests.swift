import Foundation
import Testing
@testable import SiriPlusCore

@Suite @MainActor
struct CallMonitorTests {
    private let zoom = "us.zoom.xos"
    private let start = Date(timeIntervalSince1970: 1_000)

    @Test func helpersCountAsTheirCallApp() {
        #expect(CallMonitor.callApp(for: "com.hnc.Discord.helper") == "com.hnc.Discord")
        #expect(CallMonitor.callApp(for: "com.microsoft.teams2") == "com.microsoft.teams2")
        #expect(CallMonitor.callApp(for: "com.tdesktop.Telegram") == "com.tdesktop.Telegram")
        #expect(CallMonitor.callApp(for: "com.google.Chrome") == nil)
    }

    @Test func longCallIsOfferedShortRecordingIsNot() {
        let (monitor, _, _) = makeMonitor()
        monitor.update(recordingApps: ["ru.keepcoder.Telegram", "com.google.Chrome"], now: at(0))
        monitor.update(recordingApps: ["ru.keepcoder.Telegram", "com.google.Chrome"], now: at(5))
        #expect(monitor.suggestion == nil)
        monitor.update(recordingApps: [], now: at(7))
        monitor.update(recordingApps: [zoom], now: at(8))
        monitor.update(recordingApps: [zoom], now: at(18))
        #expect(monitor.suggestion == .start(appID: zoom))
        monitor.update(recordingApps: [], now: at(19))
        #expect(monitor.suggestion == nil)
    }

    @Test func declinedCallIsOfferedAgainOnlyAfterTheNextOne() {
        let (monitor, _, _) = makeMonitor()
        monitor.update(recordingApps: [zoom], now: at(0))
        monitor.update(recordingApps: [zoom], now: at(10))
        monitor.decline()
        monitor.update(recordingApps: [zoom], now: at(60))
        #expect(monitor.suggestion == nil)

        monitor.update(recordingApps: [], now: at(70))
        monitor.update(recordingApps: [zoom], now: at(80))
        monitor.update(recordingApps: [zoom], now: at(90))
        #expect(monitor.suggestion == .start(appID: zoom))
    }

    @Test func acceptedCallStartsMeetingAndEndedCallOffersToStop() async {
        let (monitor, meeting, service) = makeMonitor()
        monitor.update(recordingApps: [zoom], now: at(0))
        monitor.update(recordingApps: [zoom], now: at(10))
        await monitor.accept()
        #expect(meeting.phase == .running)
        #expect(monitor.suggestion == nil)

        monitor.update(recordingApps: [zoom, "dev.siriplus.app"], now: at(100))
        monitor.update(recordingApps: [], now: at(110))
        monitor.update(recordingApps: [], now: at(120))
        #expect(monitor.suggestion == nil)
        monitor.update(recordingApps: [], now: at(130))
        #expect(monitor.suggestion == .stop(appID: zoom))

        await monitor.accept()
        #expect(meeting.phase == .idle)
        #expect(service.stopped)
        monitor.update(recordingApps: [], now: at(140))
        #expect(monitor.suggestion == nil)
    }

    @Test func declinedStopIsOfferedAgainAfterTheCallResumesAndEnds() async {
        let (monitor, meeting, _) = makeMonitor()
        await meeting.start()
        monitor.update(recordingApps: [zoom], now: at(0))
        monitor.update(recordingApps: [], now: at(30))
        #expect(monitor.suggestion == .stop(appID: zoom))
        monitor.decline()
        monitor.update(recordingApps: [], now: at(90))
        #expect(monitor.suggestion == nil)

        monitor.update(recordingApps: [zoom], now: at(100))
        monitor.update(recordingApps: [], now: at(130))
        #expect(monitor.suggestion == .stop(appID: zoom))
        await meeting.stop()
    }

    @Test func meetingStoppedDuringCallIsNotOfferedAgain() async {
        let (monitor, meeting, _) = makeMonitor()
        await meeting.start()
        monitor.update(recordingApps: [zoom], now: at(0))
        await meeting.stop()
        monitor.update(recordingApps: [zoom], now: at(20))
        monitor.update(recordingApps: [zoom], now: at(40))
        #expect(monitor.suggestion == nil)
    }

    @Test func meetingWithoutCallAppIsNotOfferedToStop() async {
        let (monitor, meeting, _) = makeMonitor()
        await meeting.start()
        monitor.update(recordingApps: [], now: at(0))
        monitor.update(recordingApps: [], now: at(100))
        #expect(monitor.suggestion == nil)
        await meeting.stop()
    }

    @Test func turnedOffMonitorSuggestsNothing() {
        let (monitor, _, _) = makeMonitor(enabled: false)
        monitor.update(recordingApps: [zoom], now: at(0))
        monitor.update(recordingApps: [zoom], now: at(30))
        #expect(monitor.suggestion == nil)
    }

    private func at(_ seconds: TimeInterval) -> Date { start.addingTimeInterval(seconds) }

    private func makeMonitor(enabled: Bool = true) -> (CallMonitor, MeetingModel, FakeMeetingService) {
        let service = FakeMeetingService()
        let meeting = MeetingModel(service: service, hintService: ScriptedHints()) { AssistantPreferences(hintMode: .manual) }
        let monitor = CallMonitor(meeting: meeting, usage: NoMicrophoneUsage()) { enabled }
        return (monitor, meeting, service)
    }
}

struct NoMicrophoneUsage: MicrophoneUsageSource {
    func appsUsingMicrophone() -> Set<String> { [] }
}
