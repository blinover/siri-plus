import SwiftUI

/// The subscription limits of one account: what is left of each window and when it resets.
struct UsageView: View {
    let usage: AccountUsage?
    let error: String?
    let isRefreshing: Bool
    let refresh: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label("Usage limits", systemImage: "gauge.with.dots.needle.50percent")
                    .font(.callout.weight(.medium))
                if let plan = usage?.plan {
                    Text(verbatim: plan.capitalized)
                        .font(.caption)
                        .padding(.horizontal, 6).padding(.vertical, 1)
                        .background(.quaternary, in: Capsule())
                }
                Spacer()
                if isRefreshing {
                    ProgressView().controlSize(.small)
                } else {
                    Button("Refresh", systemImage: "arrow.clockwise", action: refresh)
                        .labelStyle(.iconOnly)
                        .buttonStyle(.glass)
                        .buttonBorderShape(.circle)
                        .controlSize(.small)
                        .help("Refresh")
                }
            }
            if let usage, !usage.limits.isEmpty {
                ForEach(usage.limits) { limit in
                    LimitRow(limit: limit)
                }
                Text("Updated \(usage.fetchedAt.formatted(date: .omitted, time: .shortened))")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            } else if error == nil {
                Text("Loading…").font(.caption).foregroundStyle(.secondary)
            }
            if let error {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
    }
}

private struct LimitRow: View {
    let limit: UsageLimit

    private var tint: Color {
        switch limit.remainingPercent {
        case ..<10: .red
        case ..<30: .orange
        default: .green
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(limit.label).font(.callout)
                Spacer()
                Text("\(Int(limit.remainingPercent.rounded()))% left")
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(tint)
            }
            ProgressView(value: limit.remainingPercent, total: 100)
                .progressViewStyle(.linear)
                .tint(tint)
            if let reset = limit.resetDescription() {
                Text(reset).font(.caption).foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
    }
}
