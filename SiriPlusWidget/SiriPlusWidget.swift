import SwiftUI
import WidgetKit

/// Desktop and Notification Center widgets: ask Siri+ or start a meeting with one click.
@main
struct SiriPlusWidgets: WidgetBundle {
    var body: some Widget {
        AskWidget()
    }
}

struct AskWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "SiriPlusAsk", provider: StaticProvider()) { _ in
            AskWidgetView()
                .containerBackground(for: .widget) { WidgetBackground() }
        }
        .configurationDisplayName("Siri+")
        .description("Ask Siri+ or start a meeting.")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

struct StaticEntry: TimelineEntry {
    let date: Date
}

/// The widget shows no changing data, so one entry is enough.
struct StaticProvider: TimelineProvider {
    func placeholder(in context: Context) -> StaticEntry { StaticEntry(date: Date()) }

    func getSnapshot(in context: Context, completion: @escaping (StaticEntry) -> Void) {
        completion(StaticEntry(date: Date()))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<StaticEntry>) -> Void) {
        completion(Timeline(entries: [StaticEntry(date: Date())], policy: .never))
    }
}

enum WidgetLinks {
    /// Opens the Siri+ panel already listening.
    static let ask = URL(string: "siriplus://ask")!
    static let meeting = URL(string: "siriplus://meeting")!
}

struct AskWidgetView: View {
    @Environment(\.widgetFamily) private var family

    var body: some View {
        switch family {
        case .systemMedium:
            HStack(spacing: 14) {
                VStack(alignment: .leading, spacing: 8) {
                    Orb().frame(width: 34, height: 34)
                    Spacer(minLength: 0)
                    Text(verbatim: "Siri+").font(.headline)
                    Text("Speak or type a question").font(.caption).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                VStack(spacing: 8) {
                    Link(destination: WidgetLinks.ask) {
                        WidgetButton(title: String(localized: "Ask"), symbol: "mic.fill")
                    }
                    Link(destination: WidgetLinks.meeting) {
                        WidgetButton(title: String(localized: "Start Meeting"), symbol: "record.circle")
                    }
                }
                .frame(maxWidth: .infinity)
            }
        default:
            VStack(alignment: .leading, spacing: 6) {
                Orb().frame(width: 38, height: 38)
                Spacer(minLength: 0)
                Text("Ask Siri+").font(.headline)
                Label {
                    Text(verbatim: "⌃⌥Space")
                } icon: {
                    Image(systemName: "mic.fill")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .widgetURL(WidgetLinks.ask)
        }
    }
}

private struct WidgetButton: View {
    let title: String
    let symbol: String

    var body: some View {
        Label(title, systemImage: symbol)
            .font(.callout.weight(.medium))
            .frame(maxWidth: .infinity)
            .padding(.vertical, 9)
            .background(.white.opacity(0.14), in: Capsule())
    }
}

/// The Siri colors from the app icon.
private struct Orb: View {
    var body: some View {
        Circle()
            .fill(AngularGradient(colors: [
                Color(red: 0.20, green: 0.55, blue: 1.00), Color(red: 0.55, green: 0.35, blue: 1.00),
                Color(red: 1.00, green: 0.30, blue: 0.60), Color(red: 1.00, green: 0.62, blue: 0.22),
                Color(red: 0.20, green: 0.85, blue: 0.95), Color(red: 0.20, green: 0.55, blue: 1.00),
            ], center: .center))
            .overlay(Image(systemName: "sparkles").font(.system(size: 15, weight: .bold)).foregroundStyle(.white))
            .shadow(color: .purple.opacity(0.4), radius: 6)
    }
}

private struct WidgetBackground: View {
    var body: some View {
        LinearGradient(colors: [Color(red: 0.16, green: 0.13, blue: 0.42), Color(red: 0.04, green: 0.05, blue: 0.16)],
                       startPoint: .topLeading, endPoint: .bottomTrailing)
    }
}
