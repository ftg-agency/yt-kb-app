import SwiftUI

struct ChannelRowView: View {
    let channel: TrackedChannel
    let isPollingThis: Bool
    var isFocused: Bool = false
    var progress: ChannelProgress? = nil
    /// Display label for the global default interval (e.g. "каждые 3 часа").
    /// Used to render "По умолчанию (каждые 3 часа)" in the context menu.
    var globalIntervalLabel: String = "по настройкам"
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
                        if let perChannelLabel = perChannelOverrideLabel {
                            Text(perChannelLabel)
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
                if let countLabel = videoCountLabel {
                    Text(countLabel)
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.secondary.opacity(0.12))
                        .cornerRadius(4)
                        .help(videoCountTooltip)
                }
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
                intervalMenuItem(title: "По умолчанию (\(globalIntervalLabel))", value: nil)
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
                if let label = progressCountLabel(p) {
                    Text(label)
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
            ProgressView(value: progressFraction(p))
                .progressViewStyle(.linear)
                .tint(progressTint(p))
            if let mismatch = channelTotalMismatch(p) {
                Text(mismatch)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
    }

    /// "X / Y" counter shown during polling. Channel-wide whenever possible:
    /// `(alreadyIndexed + current) / reportedChannelTotal`. Falls back to
    /// cycle-local `current / total` when channel total is unknown.
    private func progressCountLabel(_ p: ChannelProgress) -> String? {
        guard p.total > 0 else { return nil }
        let done = p.alreadyIndexed + p.current
        if let reported = p.reportedChannelTotal, reported > 0 {
            return "\(done) / \(reported)"
        }
        // Channel total unknown (e.g. RSS path). Show "done out of best guess".
        let totalGuess = p.alreadyIndexed + p.total
        if p.alreadyIndexed > 0 {
            return "\(done) / \(totalGuess)"
        }
        return "\(p.current)/\(p.total)"
    }

    /// When YouTube reports more videos than we could enumerate AND we have
    /// nothing on disk to make up the gap, surface the difference quietly.
    private func channelTotalMismatch(_ p: ChannelProgress) -> String? {
        guard let reported = p.reportedChannelTotal, reported > 0 else { return nil }
        let projectedDone = p.alreadyIndexed + p.total
        guard p.total > 0 && reported > projectedDone + 5 else { return nil }
        return "\(projectedDone) из \(reported) — остальное подтянется"
    }

    private func progressPhaseLabel(_ p: ChannelProgress) -> String {
        switch p.phase {
        case .resolving: return "Получаю список видео…"
        case .scanning: return "Сканирую базу…"
        case .processing: return p.isInitialIndexing ? "Индексация" : "Обработка"
        case .retrying: return "Retry"
        }
    }

    /// Indeterminate display for resolving/scanning where total is unknown.
    /// During processing — channel-wide fraction when we know the channel's
    /// reported total (so the bar reflects "X out of full channel" instead of
    /// always 0→100% per cycle). Falls back to cycle-local fraction otherwise.
    private func progressFraction(_ p: ChannelProgress) -> Double? {
        switch p.phase {
        case .resolving, .scanning: return nil
        case .processing, .retrying:
            if let reported = p.reportedChannelTotal, reported > 0 {
                let done = p.alreadyIndexed + p.current
                return min(1.0, Double(done) / Double(reported))
            }
            return p.fraction
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
            let time = relativeTime(last)
            if channel.lastPollDownloaded > 0 {
                return "+\(channel.lastPollDownloaded) · \(time)"
            }
            return time
        }
        return "ещё не проверялся"
    }

    /// Badge text. When YouTube reports a total but we have fewer indexed —
    /// show "X / Y". When totals match (or only one is known) — show the
    /// single number. Falls back to nothing if both are zero.
    private var videoCountLabel: String? {
        let indexed = channel.indexedCount
        let total = channel.videoCount ?? 0
        if total > 0 && indexed > 0 && indexed < total {
            return "\(indexed) / \(total)"
        }
        if total > 0 { return "\(total)" }
        if indexed > 0 { return "\(indexed)" }
        return nil
    }

    private var videoCountTooltip: String {
        let indexed = channel.indexedCount
        let total = channel.videoCount ?? 0
        if total > 0 && indexed > 0 {
            return "Скачано \(indexed) из \(total) видео на канале"
        }
        if total > 0 { return "На канале \(total) видео" }
        return "Скачано \(indexed) видео"
    }

    private func relativeTime(_ date: Date) -> String {
        let interval = Date().timeIntervalSince(date)
        if interval < 60 { return "только что" }
        if interval < 3600 { return "\(Int(interval / 60)) мин назад" }
        if interval < 86400 { return "\(Int(interval / 3600)) ч назад" }
        return "\(Int(interval / 86400)) д назад"
    }

    /// Label suffix shown when the channel has a non-default poll interval.
    private var perChannelOverrideLabel: String? {
        guard let v = channel.pollIntervalSeconds else { return nil }
        if v == 0 { return "(только вручную)" }
        switch v {
        case 3600:  return "(ежечасно)"
        case 10800: return "(каждые 3ч)"
        case 21600: return "(каждые 6ч)"
        case 86400: return "(раз в день)"
        default:    return "(\(v / 60) мин)"
        }
    }
}
