import Combine
import Foundation

/// Notices calls in meeting apps by their microphone use and suggests starting or stopping a meeting.
@MainActor
final class CallMonitor: ObservableObject {
    enum Suggestion: Equatable {
        /// A call app has been recording for a while and no meeting is running.
        case start(appID: String)
        /// The call app heard during the running meeting released the microphone.
        case stop(appID: String)

        var appID: String {
            switch self {
            case .start(let appID), .stop(let appID): appID
            }
        }
    }

    struct Timing {
        /// Shorter microphone use, such as a Telegram voice message, is not a call.
        var startDelay: TimeInterval = 10
        /// A call app silent this long during a meeting means the call has ended.
        var stopDelay: TimeInterval = 30
        var pollInterval: Duration = .seconds(2)
    }

    @Published private(set) var suggestion: Suggestion?

    private let meeting: MeetingModel
    private let usage: any MicrophoneUsageSource
    private let isEnabled: () -> Bool
    private let timing: Timing
    private var pollTask: Task<Void, Never>?
    /// When each call app started recording.
    private var recordingSince: [String: Date] = [:]
    /// Calls not to suggest again until the app releases the microphone.
    private var declined: Set<String> = []
    /// The call app heard during the running meeting, and when it last recorded.
    private var meetingCall: (appID: String, lastHeard: Date)?
    private var stopDeclined = false
    private var wasMeetingActive = false

    init(meeting: MeetingModel, usage: any MicrophoneUsageSource, timing: Timing = Timing(), isEnabled: @escaping () -> Bool) {
        self.meeting = meeting
        self.usage = usage
        self.timing = timing
        self.isEnabled = isEnabled
    }

    func start() {
        guard pollTask == nil else { return }
        pollTask = Task { [weak self, usage, interval = timing.pollInterval] in
            while !Task.isCancelled, let self {
                self.update(recordingApps: self.isEnabled() ? usage.appsUsingMicrophone() : [])
                try? await Task.sleep(for: interval)
            }
        }
    }

    /// The call app a bundle identifier belongs to; helpers such as "com.hnc.Discord.helper" count as their app.
    static func callApp(for bundleID: String) -> String? {
        MeetingAudioSource.callApps.first { bundleID == $0 || bundleID.hasPrefix($0 + ".") }
    }

    func update(recordingApps: Set<String>, now: Date = Date()) {
        let calls = Set(recordingApps.compactMap(Self.callApp))
        for app in recordingSince.keys where !calls.contains(app) {
            recordingSince[app] = nil
            declined.remove(app)
        }
        for app in calls where recordingSince[app] == nil {
            recordingSince[app] = now
        }

        let isMeetingActive = meeting.phase != .idle
        defer { wasMeetingActive = isMeetingActive }
        guard isEnabled() else {
            suggestion = nil
            return
        }

        if isMeetingActive {
            if let app = calls.sorted().first {
                meetingCall = (app, now)
                stopDeclined = false
            }
            if let call = meetingCall, !stopDeclined, now.timeIntervalSince(call.lastHeard) >= timing.stopDelay {
                suggestion = .stop(appID: call.appID)
            } else {
                suggestion = nil
            }
        } else {
            // A meeting stopped while the call goes on: the user is done with it.
            if wasMeetingActive { declined.formUnion(calls) }
            meetingCall = nil
            stopDeclined = false
            let ready = recordingSince.filter { !declined.contains($0.key) && now.timeIntervalSince($0.value) >= timing.startDelay }
            suggestion = ready.min { $0.value < $1.value }.map { .start(appID: $0.key) }
        }
    }

    func accept() async {
        guard let suggestion else { return }
        self.suggestion = nil
        switch suggestion {
        case .start(let appID):
            // If starting fails, the error shows in the meeting tab instead of a repeated offer.
            declined.insert(appID)
            meeting.refreshSources()
            meeting.selectedSourceID = appID
            await meeting.start()
        case .stop:
            await meeting.stop()
        }
    }

    func decline() {
        switch suggestion {
        case .start(let appID): declined.insert(appID)
        case .stop: stopDeclined = true
        case nil: break
        }
        suggestion = nil
    }
}
