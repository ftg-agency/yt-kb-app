import SwiftUI

struct PopoverView: View {
    @ObservedObject var appState: AppState
    let onSettings: () -> Void
    let onQuit: () -> Void

    @State private var showingAddChannel = false
    @State private var pollErrorMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            kbPathRow
            if !appState.kbDirectoryAvailable {
                kbWarningBanner
            }
            Divider()
            channelSection
            Divider()
            footerButtons
        }
        .frame(width: 360)
        .sheet(isPresented: $showingAddChannel) {
            AddChannelView(appState: appState, isPresented: $showingAddChannel)
        }
        .onReceive(appState.$lastError) { err in
            pollErrorMessage = err
        }
        .onAppear {
            appState.refreshKBAvailability()
        }
    }

    private var kbWarningBanner: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 2) {
                Text("База знаний недоступна")
                    .font(.callout)
                    .fontWeight(.medium)
                Text("Папка не найдена — возможно отключён внешний диск. Поллинг приостановлен.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color.orange.opacity(0.1))
    }

    private var header: some View {
        HStack {
            Image(systemName: "text.book.closed.fill")
                .foregroundStyle(.secondary)
            Text("yt-kb")
                .font(.headline)
            Spacer()
            if appState.isPolling {
                ProgressView().controlSize(.small)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    private var kbPathRow: some View {
        HStack {
            Image(systemName: "folder")
                .foregroundStyle(.secondary)
            Text(appState.settings.kbDirectory?.path ?? "База не настроена")
                .lineLimit(1)
                .truncationMode(.middle)
                .foregroundStyle(.secondary)
                .font(.caption)
            Spacer()
            Button {
                onSettings()
            } label: {
                Image(systemName: "gearshape")
            }
            .buttonStyle(.plain)
            .help("Настройки")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var channelSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Отслеживаемые каналы (\(appState.channelStore.channels.count))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                if !appState.channelStore.retryQueue.isEmpty {
                    Text("retry: \(appState.channelStore.retryQueue.count)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.secondary.opacity(0.15))
                        .cornerRadius(4)
                }
            }
            .padding(.horizontal, 12)
            .padding(.top, 8)
            .padding(.bottom, 4)

            if appState.channelStore.channels.isEmpty {
                Text("Пока нет каналов. Добавьте через кнопку ниже.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 12)
            } else {
                ScrollViewReader { scrollProxy in
                    ScrollView {
                        VStack(spacing: 0) {
                            ForEach(sortedChannels) { channel in
                                ChannelRowView(
                                    channel: channel,
                                    isPollingThis: appState.pollingChannelURL == channel.url,
                                    isFocused: appState.focusChannelURL == channel.url,
                                    progress: appState.channelProgress[channel.url],
                                    globalIntervalLabel: appState.settings.pollInterval.shortLabel,
                                    onPollOnly: { Task { await PollingCoordinator.shared.pollOne(channel: channel, appState: appState) } },
                                    onToggleEnabled: {
                                        var updated = channel
                                        updated.enabled.toggle()
                                        appState.channelStore.updateChannel(updated)
                                    },
                                    onRemove: { appState.channelStore.removeChannel(url: channel.url) },
                                    onOpenFolder: { openChannelFolder(channel: channel) },
                                    onSetInterval: { value in
                                        var updated = channel
                                        updated.pollIntervalSeconds = value
                                        appState.channelStore.updateChannel(updated)
                                        appState.restartScheduler()
                                    }
                                )
                                .id(channel.url)
                            }
                        }
                    }
                    .frame(maxHeight: 220)
                    .onChange(of: appState.focusChannelURL) { newValue in
                        if let url = newValue {
                            withAnimation {
                                scrollProxy.scrollTo(url, anchor: .center)
                            }
                        }
                    }
                    .onAppear {
                        if let url = appState.focusChannelURL {
                            scrollProxy.scrollTo(url, anchor: .center)
                        }
                    }
                }
            }

            if let err = pollErrorMessage {
                Text(err)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .lineLimit(3)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 6)
            }
        }
    }

    private var footerButtons: some View {
        VStack(spacing: 6) {
            HStack(spacing: 8) {
                Button {
                    showingAddChannel = true
                } label: {
                    Label("Добавить канал", systemImage: "plus")
                        .frame(maxWidth: .infinity)
                }

                Button {
                    Task { await PollingCoordinator.shared.pollAll(appState: appState) }
                } label: {
                    Label(
                        appState.isPolling ? "Проверка идёт…" : "Проверить сейчас",
                        systemImage: appState.isPolling ? "arrow.triangle.2.circlepath" : "arrow.clockwise"
                    )
                    .frame(maxWidth: .infinity)
                }
                .keyboardShortcut("r", modifiers: .command)
                .disabled(appState.isPolling || appState.channelStore.channels.isEmpty || !appState.kbDirectoryAvailable)
            }

            Button {
                onQuit()
            } label: {
                Label("Выход", systemImage: "power")
                    .frame(maxWidth: .infinity)
            }
            .keyboardShortcut("q", modifiers: .command)
        }
        .controlSize(.regular)
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    /// Sort priority for the popover list:
    ///   1. Channel currently being polled (so user can see live progress at top)
    ///   2. Channels never polled yet (initial-indexing in progress / queued)
    ///   3. Errors (so user notices)
    ///   4. By lastPolledAt descending (most recently polled first)
    private var sortedChannels: [TrackedChannel] {
        let pollingURL = appState.pollingChannelURL
        return appState.channelStore.channels.sorted { a, b in
            // Currently polling at top
            let aPolling = (a.url == pollingURL) ? 0 : 1
            let bPolling = (b.url == pollingURL) ? 0 : 1
            if aPolling != bPolling { return aPolling < bPolling }
            // Never-polled (initial indexing) next
            let aNew = a.lastPolledAt == nil ? 0 : 1
            let bNew = b.lastPolledAt == nil ? 0 : 1
            if aNew != bNew { return aNew < bNew }
            // Errors next
            let aErr = (a.lastPollStatus == "error") ? 0 : 1
            let bErr = (b.lastPollStatus == "error") ? 0 : 1
            if aErr != bErr { return aErr < bErr }
            // Newest poll first
            switch (a.lastPolledAt, b.lastPolledAt) {
            case let (la?, lb?): return la > lb
            case (.some, .none): return true
            case (.none, .some): return false
            case (.none, .none): return a.name < b.name
            }
        }
    }

    private func openChannelFolder(channel: TrackedChannel) {
        guard let kb = appState.settings.kbDirectory else { return }
        do {
            _ = try appState.settings.withKBAccess { _ in
                let dir = kb.appendingPathComponent(channel.name)
                if FileManager.default.fileExists(atPath: dir.path) {
                    NSWorkspace.shared.open(dir)
                } else {
                    NSWorkspace.shared.open(kb)
                }
            }
        } catch {
            Logger.shared.warn("openChannelFolder failed: \(error)")
        }
    }
}
