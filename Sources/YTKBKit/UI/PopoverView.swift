import SwiftUI
import AppKit

struct PopoverView: View {
    @ObservedObject var appState: AppState
    let onSettings: () -> Void
    let onQuit: () -> Void

    @State private var pollErrorMessage: String?

    // Inline "Add channel" form state
    @State private var addExpanded: Bool = false
    @State private var addURL: String = ""
    @State private var addResolving: Bool = false
    @State private var addError: String?
    @State private var addResolvedName: String?
    @State private var addResolvedChannelId: String?
    @State private var addResolvedVideoCount: Int?
    @FocusState private var addURLFocused: Bool

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
                                    isPollingThis: appState.pollingChannelURLs.contains(channel.url),
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

    @ViewBuilder
    private var addChannelInline: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                TextField("https://www.youtube.com/@handle", text: $addURL)
                    .textFieldStyle(.roundedBorder)
                    .focused($addURLFocused)
                    .disabled(addResolving || addResolvedName != nil)
                    .onSubmit {
                        if addResolvedName == nil {
                            resolveAdd()
                        } else {
                            saveAdd()
                        }
                    }
                if let _ = addResolvedName {
                    Button {
                        saveAdd()
                    } label: {
                        Image(systemName: "checkmark")
                    }
                    .keyboardShortcut(.defaultAction)
                    .help("Добавить")
                } else {
                    Button {
                        resolveAdd()
                    } label: {
                        if addResolving {
                            ProgressView().controlSize(.small)
                        } else {
                            Image(systemName: "magnifyingglass")
                        }
                    }
                    .keyboardShortcut(.defaultAction)
                    .disabled(addResolving || addURL.trimmingCharacters(in: .whitespaces).isEmpty)
                    .help("Проверить URL")
                }
                Button {
                    cancelAdd()
                } label: {
                    Image(systemName: "xmark")
                }
                .keyboardShortcut(.cancelAction)
                .help("Отмена")
            }

            if let resolvedName = addResolvedName {
                HStack(spacing: 4) {
                    Image(systemName: "checkmark.seal.fill")
                        .foregroundStyle(.green)
                    Text("Найден: \(resolvedName)")
                        .font(.caption)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            if let err = addError {
                Text(err)
                    .font(.caption2)
                    .foregroundStyle(.red)
                    .lineLimit(3)
            }
        }
    }

    private var footerButtons: some View {
        VStack(spacing: 6) {
            if addExpanded {
                addChannelInline
            } else {
                HStack(spacing: 8) {
                    Button {
                        beginAdd()
                    } label: {
                        Label("Добавить канал", systemImage: "plus")
                            .frame(maxWidth: .infinity)
                    }

                    if appState.isPolling {
                        Button {
                            Task { await PollingCoordinator.shared.cancel() }
                        } label: {
                            Label("Остановить", systemImage: "stop.circle")
                                .frame(maxWidth: .infinity)
                        }
                        .keyboardShortcut(".", modifiers: .command)
                        .help("Остановить индексацию (⌘.)")
                    } else {
                        Button {
                            Task { await PollingCoordinator.shared.pollAll(appState: appState) }
                        } label: {
                            Label("Проверить сейчас", systemImage: "arrow.clockwise")
                                .frame(maxWidth: .infinity)
                        }
                        .keyboardShortcut("r", modifiers: .command)
                        .disabled(appState.channelStore.channels.isEmpty || !appState.kbDirectoryAvailable)
                    }
                }
            }

            if let update = appState.availableUpdate {
                updateBanner(update)
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

    @ViewBuilder
    private func updateBanner(_ update: AppUpdate) -> some View {
        if let progress = appState.updateInstallProgress {
            VStack(spacing: 4) {
                HStack {
                    Text(progress.phase)
                        .font(.caption)
                    Spacer()
                }
                ProgressView(value: progress.fraction >= 0 ? progress.fraction : nil)
                    .progressViewStyle(.linear)
            }
        } else {
            Button {
                appState.installAvailableUpdate()
            } label: {
                Label("Обновить до \(update.version) и перезапустить", systemImage: "arrow.down.circle")
                    .frame(maxWidth: .infinity)
            }
            .controlSize(.regular)
            .buttonStyle(.borderedProminent)
        }
    }

    // MARK: - Add channel inline form

    private func beginAdd() {
        addExpanded = true
        addError = nil
        addResolvedName = nil
        addResolvedChannelId = nil
        addURL = ""
        // Pre-fill from clipboard if it looks like a YouTube URL
        if let candidate = NSPasteboard.general.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines),
           candidate.contains("youtube.com") || candidate.contains("youtu.be") {
            addURL = candidate
        }
        // Defer focus so SwiftUI has finished mounting the TextField
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            addURLFocused = true
        }
    }

    private func cancelAdd() {
        addExpanded = false
        addURL = ""
        addError = nil
        addResolvedName = nil
        addResolvedChannelId = nil
        addResolving = false
    }

    private func resolveAdd() {
        let raw = addURL.trimmingCharacters(in: .whitespaces)
        guard !raw.isEmpty else { return }
        addError = nil
        addResolvedName = nil
        addResolvedChannelId = nil
        addResolvedVideoCount = nil
        addResolving = true

        let config = appState.settings.ytdlpConfig
        Task {
            defer { Task { @MainActor in addResolving = false } }
            do {
                let resolver = ChannelResolver(runner: YTDLPRunner.shared, config: config)
                let result = try await resolver.resolveMetadata(channelURL: raw)
                await MainActor.run {
                    addResolvedName = result.name
                    addResolvedChannelId = result.channelId
                    addResolvedVideoCount = result.reportedTotalCount
                }
            } catch {
                await MainActor.run {
                    self.addError = "\(error)"
                }
            }
        }
    }

    private func saveAdd() {
        guard let name = addResolvedName else { return }
        let url = addURL.trimmingCharacters(in: .whitespaces)
        let channel = TrackedChannel(
            url: url,
            channelId: addResolvedChannelId,
            name: name,
            addedAt: Date(),
            videoCount: addResolvedVideoCount,
            folderName: resolveExistingFolderName(name: name, url: url)
        )
        appState.channelStore.addChannel(channel)
        cancelAdd()
        Task { await PollingCoordinator.shared.pollOne(channel: channel, appState: appState) }
    }

    /// If KB already has a folder for this channel (from a prior install or a
    /// manual rename), reuse its name. Otherwise return nil and let the first
    /// poll create a clean-slug folder and pin it.
    private func resolveExistingFolderName(name: String, url: String) -> String? {
        guard let kb = appState.settings.kbDirectory else { return nil }
        let started = kb.startAccessingSecurityScopedResource()
        defer { if started { kb.stopAccessingSecurityScopedResource() } }
        return KBConsolidator.existingFolderName(forURL: url, in: kb)
    }

    /// Sort priority for the popover list:
    ///   1. Channel currently being polled (so user can see live progress at top)
    ///   2. Channels never polled yet (initial-indexing in progress / queued)
    ///   3. Errors (so user notices)
    ///   4. By lastPolledAt descending (most recently polled first)
    private var sortedChannels: [TrackedChannel] {
        let pollingURLs = appState.pollingChannelURLs
        return appState.channelStore.channels.sorted { a, b in
            let aPolling = pollingURLs.contains(a.url) ? 0 : 1
            let bPolling = pollingURLs.contains(b.url) ? 0 : 1
            if aPolling != bPolling { return aPolling < bPolling }
            let aNew = a.lastPolledAt == nil ? 0 : 1
            let bNew = b.lastPolledAt == nil ? 0 : 1
            if aNew != bNew { return aNew < bNew }
            let aErr = (a.lastPollStatus == "error") ? 0 : 1
            let bErr = (b.lastPollStatus == "error") ? 0 : 1
            if aErr != bErr { return aErr < bErr }
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
                let dirName = channel.folderName ?? Slugify.slug(channel.name.isEmpty ? "unknown-channel" : channel.name)
                let dir = kb.appendingPathComponent(dirName)
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
