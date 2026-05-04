import SwiftUI

/// Channel row used inside Settings → Каналы. Wider than the popover row,
/// surfaces the per-channel poll interval as a Picker (rather than a context
/// menu), and exposes enable/disable + remove inline.
struct SettingsChannelRow: View {
    let channel: TrackedChannel
    let globalLabel: String
    let progress: ChannelProgress?
    let isPollingThis: Bool
    let folderName: String?
    let onSetInterval: (Int?) -> Void
    let onToggleEnabled: () -> Void
    let onPollOnly: () -> Void
    let onRemove: () -> Void
    let onOpenFolder: () -> Void

    private static let intervalOptions: [(label: String, value: Int?)] = [
        ("По умолчанию", nil),
        ("Каждый час", 3600),
        ("Каждые 3 часа", 10800),
        ("Каждые 6 часов", 21600),
        ("Раз в день", 86400),
        ("Только вручную", 0)
    ]

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

                Picker(selection: intervalBinding) {
                    ForEach(Self.intervalOptions, id: \.value) { opt in
                        Text(opt.value == nil ? "По умолчанию (\(globalLabel))" : opt.label)
                            .tag(opt.value)
                    }
                } label: {
                    Text("Частота")
                }
                .pickerStyle(.menu)
                .frame(width: 220)
                .disabled(!channel.enabled)

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

    private var intervalBinding: Binding<Int?> {
        Binding(get: { channel.pollIntervalSeconds }, set: { onSetInterval($0) })
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
                if p.total > 0 {
                    Text("\(p.current)/\(p.total)")
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
            if let reported = p.reportedChannelTotal, reported > 0, p.total > 0, reported > p.total + 5 {
                Text("\(p.total) из \(reported) — остальное подтянется на следующих проверках.")
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

    private func relativeTime(_ date: Date) -> String {
        let interval = Date().timeIntervalSince(date)
        if interval < 60 { return "проверен только что" }
        if interval < 3600 { return "проверен \(Int(interval / 60)) мин назад" }
        if interval < 86400 { return "проверен \(Int(interval / 3600)) ч назад" }
        return "проверен \(Int(interval / 86400)) д назад"
    }

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
            return "Скачано \(indexed) из \(total) видео"
        }
        if total > 0 { return "На канале \(total) видео" }
        return "Скачано \(indexed) видео"
    }
}
