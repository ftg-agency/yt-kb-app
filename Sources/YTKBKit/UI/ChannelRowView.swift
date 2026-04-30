import SwiftUI

struct ChannelRowView: View {
    let channel: TrackedChannel
    let isPollingThis: Bool
    var isFocused: Bool = false
    var progress: ChannelProgress? = nil
    let onPollOnly: () -> Void
    let onToggleEnabled: () -> Void
    let onRemove: () -> Void
    let onOpenFolder: () -> Void
    let onSetInterval: (Int?) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
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
                        if channel.pollIntervalSeconds == 0 {
                            Text("(только вручную)")
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

            if let progress, isPollingThis {
                progressSection(progress)
            }
        }
        .contentShape(Rectangle())
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .opacity(channel.enabled ? 1.0 : 0.6)
        .background(isFocused ? Color.accentColor.opacity(0.18) : Color.clear)
        .animation(.easeInOut(duration: 0.4), value: isFocused)
        .contextMenu {
            Button("Открыть папку в Finder", action: onOpenFolder)
            Button("Проверить только этот канал", action: onPollOnly)
                .disabled(isPollingThis || !channel.enabled)
            Divider()
            Menu("Частота проверки") {
                intervalMenuItem(title: "По умолчанию", value: nil)
                Divider()
                intervalMenuItem(title: "Каждый час", value: 3600)
                intervalMenuItem(title: "Каждые 3 часа", value: 10800)
                intervalMenuItem(title: "Каждые 6 часов", value: 21600)
                intervalMenuItem(title: "Раз в день", value: 86400)
                Divider()
                intervalMenuItem(title: "Только вручную", value: 0)
            }
            Button(channel.enabled ? "Отключить" : "Включить", action: onToggleEnabled)
            Button("Удалить", role: .destructive, action: onRemove)
        }
    }

    @ViewBuilder
    private func intervalMenuItem(title: String, value: Int?) -> some View {
        Button {
            onSetInterval(value)
        } label: {
            if channel.pollIntervalSeconds == value {
                Label(title, systemImage: "checkmark")
            } else {
                Text(title)
            }
        }
    }

    @ViewBuilder
    private func progressSection(_ p: ChannelProgress) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Text(progressPhaseLabel(p))
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
                Spacer()
                if p.total > 0 {
                    Text("\(p.current)/\(p.total)")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
            ProgressView(value: progressFraction(p))
                .progressViewStyle(.linear)
                .tint(progressTint(p))
            if let label = p.label, !label.isEmpty {
                Text(label)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
    }

    private func progressPhaseLabel(_ p: ChannelProgress) -> String {
        switch p.phase {
        case .resolving: return "Получаю список видео…"
        case .scanning: return "Сканирую базу…"
        case .processing: return p.isInitialIndexing ? "Индексация" : "Обработка"
        case .retrying: return "Retry"
        }
    }

    /// Indeterminate display for resolving/scanning where total is unknown:
    /// SwiftUI's ProgressView with value=nil shows the indeterminate animation.
    private func progressFraction(_ p: ChannelProgress) -> Double? {
        switch p.phase {
        case .resolving, .scanning: return nil
        case .processing, .retrying: return p.fraction
        }
    }

    private func progressTint(_ p: ChannelProgress) -> Color {
        if p.phase == .retrying { return .orange }
        if p.isInitialIndexing { return .green }
        return .accentColor
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
