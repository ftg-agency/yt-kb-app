import SwiftUI

/// Channel row used inside Settings → Каналы. Wider than the popover row,
/// exposes enable/disable + remove inline. v2.0.0: per-channel poll interval
/// removed — single global interval applies to all channels.
struct SettingsChannelRow: View {
    let channel: TrackedChannel
    let progress: ChannelProgress?
    let isPollingThis: Bool
    let folderName: String?
    let onToggleEnabled: () -> Void
    let onPollOnly: () -> Void
    let onRemove: () -> Void
    let onOpenFolder: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Toggle(isOn: Binding(get: { channel.enabled }, set: { _ in onToggleEnabled() })) {
                    EmptyView()
                }
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(channel.name)
                            .font(.body)
                            .foregroundStyle(channel.enabled ? .primary : .secondary)
                        if let countLabel = videoCountLabel {
                            Text(countLabel)
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 1)
                                .background(Color.secondary.opacity(0.12))
                                .cornerRadius(4)
                                .help(videoCountTooltip)
                        }
                    }
                    Text(channel.url)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    folderRow
                }

                Spacer()

                Menu {
                    Button("Проверить только этот канал", action: onPollOnly)
                        .disabled(isPollingThis || !channel.enabled)
                    Button("Удалить канал", role: .destructive, action: onRemove)
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
            }

            if isPollingThis, let progress {
                progressFooter(progress)
            } else if let last = channel.lastPolledAt {
                Text(relativeTime(last))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            } else if !channel.enabled {
                Text("опрос отключён")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            } else {
                Text("ещё не индексировался")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 8)
    }

    @ViewBuilder
    private var folderRow: some View {
        if let folderName, !folderName.isEmpty {
            Button(action: onOpenFolder) {
                HStack(spacing: 4) {
                    Image(systemName: "folder")
                        .font(.caption2)
                    Text(folderName)
                        .font(.caption2)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Открыть папку канала в Finder")
        }
    }

    @ViewBuilder
    private func progressFooter(_ p: ChannelProgress) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Text(phaseLabel(p))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                if let label = progressCountLabel(p) {
                    Text(label)
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                if let label = p.label, !label.isEmpty {
                    Text("·")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                    Text(label)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer(minLength: 0)
            }
            ProgressView(value: progressFraction(p))
                .progressViewStyle(.linear)
                .tint(progressTint(p))
            if let mismatch = channelTotalMismatch(p) {
                Text(mismatch)
                    .font(.caption2)
                    .foregroundStyle(.orange)
                    .lineLimit(2)
            }
        }
    }

    private func phaseLabel(_ p: ChannelProgress) -> String {
        switch p.phase {
        case .resolving:  return "Получаю список видео…"
        case .scanning:   return "Сканирую базу…"
        case .processing: return p.isInitialIndexing ? "Индексация" : "Обработка"
        case .retrying:   return "Retry"
        }
    }

    /// Channel-wide "85% (X/Y)" when we know the channel total, else cycle-local.
    private func progressCountLabel(_ p: ChannelProgress) -> String? {
        guard p.total > 0 else { return nil }
        let done = p.alreadyIndexed + p.current
        if let reported = p.reportedChannelTotal, reported > 0 {
            let pct = Int((Double(done) / Double(reported)) * 100)
            return "\(pct)% (\(done)/\(reported))"
        }
        let totalGuess = p.alreadyIndexed + p.total
        if p.alreadyIndexed > 0 && totalGuess > 0 {
            let pct = Int((Double(done) / Double(totalGuess)) * 100)
            return "\(pct)% (\(done)/\(totalGuess))"
        }
        let pct = Int((Double(p.current) / Double(p.total)) * 100)
        return "\(pct)% (\(p.current)/\(p.total))"
    }

    /// Channel-wide fraction whenever we know the reported total.
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

    /// Surface the gap when we project we'll finish below YouTube's reported
    /// total — explains "the rest will pull in on later cycles".
    private func channelTotalMismatch(_ p: ChannelProgress) -> String? {
        guard let reported = p.reportedChannelTotal, reported > 0 else { return nil }
        let projectedDone = p.alreadyIndexed + p.total
        guard p.total > 0 && reported > projectedDone + 5 else { return nil }
        return "\(projectedDone) из \(reported) — остальное подтянется на следующих проверках."
    }

    private func progressTint(_ p: ChannelProgress) -> Color {
        if p.phase == .retrying { return .orange }
        if p.isInitialIndexing { return .green }
        return .accentColor
    }

    private func relativeTime(_ date: Date) -> String {
        let interval = Date().timeIntervalSince(date)
        if interval < 60 { return "проверен только что" }
        if interval < 3600 { return "проверен \(Int(interval / 60)) мин назад" }
        if interval < 86400 { return "проверен \(Int(interval / 3600)) ч назад" }
        return "проверен \(Int(interval / 86400)) д назад"
    }

    /// Live counts during polling (from ChannelProgress); persisted otherwise.
    private var videoCountLabel: String? {
        if isPollingThis, let p = progress {
            let done = p.alreadyIndexed + p.current
            if let reported = p.reportedChannelTotal, reported > 0 {
                return "\(done) / \(reported)"
            }
            if p.alreadyIndexed > 0 { return "\(done)" }
        }
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
            return "Скачано \(indexed) из \(total) видео"
        }
        if total > 0 { return "На канале \(total) видео" }
        return "Скачано \(indexed) видео"
    }
}
