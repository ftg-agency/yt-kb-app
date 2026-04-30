import SwiftUI

struct ChannelRowView: View {
    let channel: TrackedChannel
    let isPollingThis: Bool
    let onPollOnly: () -> Void
    let onToggleEnabled: () -> Void
    let onRemove: () -> Void
    let onOpenFolder: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            statusIcon
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 4) {
                    Text(channel.name)
                        .font(.callout)
                        .lineLimit(1)
                        .foregroundStyle(channel.enabled ? .primary : .secondary)
                    if !channel.enabled {
                        Text("(отключён)")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }
                Text(subtitle)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
        }
        .contentShape(Rectangle())
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .opacity(channel.enabled ? 1.0 : 0.6)
        .contextMenu {
            Button("Открыть папку в Finder", action: onOpenFolder)
            Button("Проверить только этот канал", action: onPollOnly)
                .disabled(isPollingThis || !channel.enabled)
            Divider()
            Button(channel.enabled ? "Отключить" : "Включить", action: onToggleEnabled)
            Button("Удалить", role: .destructive, action: onRemove)
        }
    }

    @ViewBuilder
    private var statusIcon: some View {
        if isPollingThis {
            ProgressView().controlSize(.small)
        } else if !channel.enabled {
            Image(systemName: "pause.circle")
                .foregroundStyle(.secondary)
        } else if channel.lastPollStatus == "error" {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
        } else if channel.lastPolledAt != nil {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
        } else {
            Image(systemName: "circle.dashed")
                .foregroundStyle(.secondary)
        }
    }

    private var subtitle: String {
        if isPollingThis { return "проверяется…" }
        if !channel.enabled { return "не опрашивается" }
        if let err = channel.lastPollError, channel.lastPollStatus == "error" {
            return "ошибка: \(err)"
        }
        if let last = channel.lastPolledAt {
            return relativeTime(last)
        }
        return "ещё не проверялся"
    }

    private func relativeTime(_ date: Date) -> String {
        let interval = Date().timeIntervalSince(date)
        if interval < 60 { return "только что" }
        if interval < 3600 { return "\(Int(interval / 60)) мин назад" }
        if interval < 86400 { return "\(Int(interval / 3600)) ч назад" }
        return "\(Int(interval / 86400)) д назад"
    }
}
