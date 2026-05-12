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
    @FocusState private var addURLFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            kbPathRow
            if !appState.kbDirectoryAvailable {
                kbWarningBanner
            }
            if appState.botCheckActive {
                botCheckBanner
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

    private var botCheckBanner: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.shield.fill")
                .foregroundStyle(.white)
            VStack(alignment: .leading, spacing: 2) {
                Text("YouTube требует подтверждение")
                    .font(.callout)
                    .fontWeight(.medium)
                    .foregroundStyle(.white)
                Text("Войдите в YouTube в выбранном браузере и нажмите «Проверить сейчас».")
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.9))
                    .lineLimit(2)
            }
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color.red)
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
                Text("Каналы (\(appState.channelStore.channels.count))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                if appState.queuedChannelCount > 0 {
                    Text("+\(appState.queuedChannelCount) в очереди")
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
                                    onPollOnly: { Task { await PollingCoordinator.shared.pollOne(channel: channel, appState: appState) } },
                                    onToggleEnabled: {
                                        var updated = channel
                                        updated.enabled.toggle()
                                        appState.channelStore.updateChannel(updated)
                                    },
                                    onRemove: { appState.channelStore.removeChannel(url: channel.url) },
                                    onOpenFolder: { openChannelFolder(channel: channel) }
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

    private func relativeTime(_ date: Date) -> String {
        let interval = Date().timeIntervalSince(date)
        if interval < 60 { return "только что" }
        if interval < 3600 { return "\(Int(interval / 60)) мин назад" }
        if interval < 86400 { return "\(Int(interval / 3600)) ч назад" }
        return "\(Int(interval / 86400)) д назад"
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
        addResolving = true

        let config = appState.settings.ytdlpConfig
        Task {
            let tStart = Date()
            Logger.shared.info("addChannel ▶▶▶ \(raw)")
            defer {
                let ms = Int(Date().timeIntervalSince(tStart) * 1000)
                Logger.shared.info("addChannel ◀◀◀ wallclock=\(ms)ms")
                Task { @MainActor in addResolving = false }
            }
            let resolver = ChannelResolver(runner: YTDLPRunner.shared, config: config)
            let lite: ResolvedChannelLite

            // Path 1: HTML scrape (~500ms, no yt-dlp). Works for any public channel.
            do {
                let html = try await ChannelPageFetcher.shared.fetchMetadata(channelURL: raw)
                lite = ResolvedChannelLite(
                    name: html.name,
                    channelId: html.channelId,
                    channelURL: html.canonicalURL
                )
                Logger.shared.info("addChannel · channelPage win")
                await MainActor.run {
                    addResolvedName = lite.name
                    addResolvedChannelId = lite.channelId
                }
                return
            } catch ChannelPageFetcher.FetchError.http(let code) where code == 404 {
                // Definitive — channel doesn't exist. Skip yt-dlp fallback
                // (it would just retry 404 for ~2 minutes via cascade).
                Logger.shared.warn("addChannel · channel не существует (HTTP 404)")
                await MainActor.run { self.addError = "Канал не существует" }
                return
            } catch {
                Logger.shared.warn("addChannel · channelPage FAIL (\(error)) — fallback to yt-dlp quickResolve")
            }

            // Path 2: yt-dlp quickResolve (~3-10s).
            do {
                lite = try await resolver.quickResolve(channelURL: raw)
                Logger.shared.info("addChannel · quickResolve win")
            } catch {
                Logger.shared.warn("addChannel · quickResolve FAIL (\(error)) — fallback to full resolveMetadata")
                // Path 3: full resolveMetadata with cascade (~30s+).
                do {
                    let full = try await resolver.resolveMetadata(channelURL: raw)
                    lite = ResolvedChannelLite(
                        name: full.name,
                        channelId: full.channelId,
                        channelURL: full.channelURL
                    )
                    Logger.shared.info("addChannel · resolveMetadata fallback win")
                } catch {
                    Logger.shared.error("addChannel · ALL paths failed: \(error)")
                    await MainActor.run { self.addError = "\(error)" }
                    return
                }
            }
            await MainActor.run {
                addResolvedName = lite.name
                addResolvedChannelId = lite.channelId
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
            videoCount: nil,
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
