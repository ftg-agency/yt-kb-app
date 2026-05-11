import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct SettingsView: View {
    @ObservedObject var appState: AppState

    enum SettingsSection: String, CaseIterable, Identifiable {
        case general, channels, schedule, advanced, about
        var id: String { rawValue }
        var label: String {
            switch self {
            case .general: return "Базовые"
            case .channels: return "Каналы"
            case .schedule: return "Расписание"
            case .advanced: return "Дополнительно"
            case .about: return "О приложении"
            }
        }
        var systemImage: String {
            switch self {
            case .general: return "gear"
            case .channels: return "list.bullet"
            case .schedule: return "clock"
            case .advanced: return "wrench.and.screwdriver"
            case .about: return "info.circle"
            }
        }
    }

    @State private var selection: SettingsSection = .general
    @State private var showKBImportInfo: Bool = false
    @State private var showJSONImportInfo: Bool = false

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Divider()
            detail
        }
        .frame(minWidth: 720, idealWidth: 820, minHeight: 480, idealHeight: 560)
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(SettingsSection.allCases) { section in
                Button {
                    selection = section
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: section.systemImage)
                            .frame(width: 18)
                            .foregroundStyle(selection == section ? Color.white : Color.secondary)
                        Text(section.label)
                            .foregroundStyle(selection == section ? Color.white : Color.primary)
                        Spacer()
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(
                        RoundedRectangle(cornerRadius: 6)
                            .fill(selection == section ? Color.accentColor : Color.clear)
                    )
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            Spacer()
        }
        .padding(8)
        .frame(width: 220, alignment: .top)
        .frame(maxHeight: .infinity)
        .background(Color(NSColor.windowBackgroundColor).opacity(0.6))
    }

    private var detail: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(selection.label)
                    .font(.title2.bold())
                Spacer()
            }
            .padding(.horizontal, 24)
            .padding(.top, 16)
            .padding(.bottom, 8)
            ScrollView {
                Group {
                    switch selection {
                    case .general:  generalTab
                    case .channels: channelsTab
                    case .schedule: scheduleTab
                    case .advanced: advancedTab
                    case .about:    aboutTab
                    }
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 20)
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var channelsTab: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Каналы (\(appState.channelStore.channels.count))").font(.headline)
                Spacer()
                Button("Переиндексировать всё") { reindexAll() }
                    .disabled(appState.isPolling || appState.channelStore.channels.isEmpty)
                Button("Проверить сейчас") {
                    Task { await PollingCoordinator.shared.pollAll(appState: appState) }
                }
                .disabled(appState.isPolling || appState.channelStore.channels.isEmpty || !appState.kbDirectoryAvailable)
            }
            Text("Здесь можно поменять частоту проверки для каждого канала или временно отключить опрос. По умолчанию каналы опрашиваются с частотой из вкладки «Расписание» (\(appState.settings.pollInterval.shortLabel)).")
                .font(.caption)
                .foregroundStyle(.secondary)

            if appState.channelStore.channels.isEmpty {
                VStack {
                    Spacer()
                    Text("Список пуст. Добавьте канал через popover в menu bar.")
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                channelList
            }
        }
        .padding(.vertical, 8)
    }

    private var channelList: some View {
        ScrollView {
            VStack(spacing: 0) {
                ForEach(appState.channelStore.channels) { channel in
                    SettingsChannelRow(
                        channel: channel,
                        globalLabel: appState.settings.pollInterval.shortLabel,
                        progress: appState.channelProgress[channel.url],
                        isPollingThis: appState.pollingChannelURLs.contains(channel.url),
                        folderName: resolvedFolderName(for: channel),
                        onSetInterval: { value in
                            var updated = channel
                            updated.pollIntervalSeconds = value
                            appState.channelStore.updateChannel(updated)
                            appState.restartScheduler()
                        },
                        onToggleEnabled: {
                            var updated = channel
                            updated.enabled.toggle()
                            appState.channelStore.updateChannel(updated)
                        },
                        onPollOnly: { Task { await PollingCoordinator.shared.pollOne(channel: channel, appState: appState) } },
                        onRemove: { appState.channelStore.removeChannel(url: channel.url) },
                        onOpenFolder: { openChannelFolder(channel) }
                    )
                    Divider()
                }
            }
        }
    }

    /// Folder name to display in the channel row. Falls back to a fresh slug
    /// when the channel hasn't been pinned yet (e.g. brand-new install,
    /// pre-consolidator state.json without `folderName`).
    private func resolvedFolderName(for channel: TrackedChannel) -> String? {
        if let pinned = channel.folderName, !pinned.isEmpty { return pinned }
        let derived = Slugify.slug(channel.name.isEmpty ? "unknown-channel" : channel.name)
        return derived.isEmpty ? nil : derived
    }

    private func openChannelFolder(_ channel: TrackedChannel) {
        guard let kb = appState.settings.kbDirectory else { return }
        do {
            _ = try appState.settings.withKBAccess { _ in
                let dirName = resolvedFolderName(for: channel) ?? ""
                let dir = dirName.isEmpty ? kb : kb.appendingPathComponent(dirName)
                if FileManager.default.fileExists(atPath: dir.path) {
                    NSWorkspace.shared.open(dir)
                } else {
                    NSWorkspace.shared.open(kb)
                }
            }
        } catch {
            Logger.shared.warn("openChannelFolder (Settings) failed: \(error)")
        }
    }

    private func reindexAll() {
        let alert = NSAlert()
        alert.messageText = "Переиндексировать все каналы?"
        alert.informativeText = "Каналы будут проверены заново. Уже скачанные транскрипты не перезапишутся — только подтянем то, что пропустили."
        alert.addButton(withTitle: "Переиндексировать")
        alert.addButton(withTitle: "Отмена")
        alert.alertStyle = .informational
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        for channel in appState.channelStore.channels {
            var updated = channel
            updated.lastPolledAt = nil
            updated.lastPollStatus = nil
            updated.lastPollError = nil
            appState.channelStore.updateChannel(updated)
        }
        Task { await PollingCoordinator.shared.pollAll(appState: appState) }
    }

    private var generalTab: some View {
        Form {
            Section("База знаний") {
                HStack {
                    Text(appState.settings.kbDirectory?.path ?? "не выбрана")
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Выбрать…") { pickKBDirectory() }
                }
                if let url = appState.settings.kbDirectory {
                    Button("Открыть в Finder") {
                        do {
                            _ = try appState.settings.withKBAccess { u in
                                NSWorkspace.shared.open(u)
                            }
                        } catch {
                            NSWorkspace.shared.open(url)
                        }
                    }
                    Button("Пересканировать KB и добавить новые каналы") {
                        rediscover()
                    }
                }
            }
            Section("Браузер для входа в YouTube") {
                Picker("Браузер", selection: Binding(
                    get: { appState.settings.browser },
                    set: { appState.settings.setBrowser($0) }
                )) {
                    ForEach(Settings.BrowserChoice.allCases) { choice in
                        Text(choice.displayName).tag(choice)
                    }
                }
                Text("Нужно чтобы YouTube не блокировал доступ. Войдите в YouTube в этом браузере один раз.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("Запуск") {
                Toggle("Запускать при входе в систему", isOn: Binding(
                    get: { appState.settings.launchAtLogin },
                    set: { LoginItemController.setEnabled($0, settings: appState.settings) }
                ))
                Text("Чтобы новые видео индексировались в фоне без вашего участия.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private var scheduleTab: some View {
        Form {
            Section("Фоновый опрос") {
                Toggle("Опрашивать каналы автоматически", isOn: Binding(
                    get: { appState.settings.backgroundPollingEnabled },
                    set: {
                        appState.settings.setBackgroundPollingEnabled($0)
                        appState.restartScheduler()
                    }
                ))
                Picker("Частота по умолчанию", selection: Binding(
                    get: { appState.settings.pollInterval },
                    set: {
                        appState.settings.setPollInterval($0)
                        appState.restartScheduler()
                    }
                )) {
                    ForEach(Settings.PollInterval.allCases) { interval in
                        Text(interval.displayName).tag(interval)
                    }
                }
                .disabled(!appState.settings.backgroundPollingEnabled)
                Text("Эта частота применяется ко всем каналам у которых не задана своя — её можно поменять для каждого канала отдельно во вкладке «Каналы».")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("Параллельность") {
                Stepper(
                    "Каналов параллельно: \(appState.settings.maxConcurrentChannels)",
                    value: Binding(
                        get: { appState.settings.maxConcurrentChannels },
                        set: { appState.settings.setMaxConcurrentChannels($0) }
                    ),
                    in: 1...4
                )
                Stepper(
                    "Видео в канале параллельно: \(appState.settings.maxConcurrentVideos)",
                    value: Binding(
                        get: { appState.settings.maxConcurrentVideos },
                        set: { appState.settings.setMaxConcurrentVideos($0) }
                    ),
                    in: 1...8
                )
                Text("Больше — быстрее, но YouTube может временно ограничить доступ.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("Энергосбережение") {
                Toggle("Не давать Mac засыпать во время индексации", isOn: Binding(
                    get: { appState.settings.preventSleepDuringPoll },
                    set: { appState.settings.setPreventSleepDuringPoll($0) }
                ))
                Text("Если ноутбук закрыт и работает от батареи — macOS всё равно может приостановить работу.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("Сеть") {
                HStack {
                    Text("Пауза между запросами:")
                    Slider(
                        value: Binding(
                            get: { appState.settings.sleepRequests },
                            set: { appState.settings.setSleepRequests($0) }
                        ),
                        in: 0...5,
                        step: 0.5
                    )
                    Text("\(appState.settings.sleepRequests, specifier: "%.1f") c")
                        .monospacedDigit()
                        .frame(width: 50, alignment: .trailing)
                }
                Text("Снижает шанс что YouTube начнёт временно ограничивать доступ.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private var advancedTab: some View {
        Form {
            Section("Приоритет языков субтитров") {
                Text("Перетащите чтобы изменить порядок. Особые токены: @original — язык оригинала, @english, @any — любой.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                LanguagePriorityList(appState: appState)
            }
            Section("Импорт / экспорт") {
                HStack {
                    Button("Импортировать каналы из существующей KB-папки") { rediscover() }
                    Button {
                        showKBImportInfo.toggle()
                    } label: {
                        Image(systemName: "info.circle")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.borderless)
                    .popover(isPresented: $showKBImportInfo, arrowEdge: .top) {
                        kbImportInfoPopover
                    }
                    Spacer()
                }
                Button("Экспортировать список каналов в JSON…") { exportChannels() }
                    .disabled(appState.channelStore.channels.isEmpty)
                HStack {
                    Button("Импортировать каналы из JSON…") { importChannels() }
                    Button {
                        showJSONImportInfo.toggle()
                    } label: {
                        Image(systemName: "info.circle")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.borderless)
                    .popover(isPresented: $showJSONImportInfo, arrowEdge: .top) {
                        jsonImportInfoPopover
                    }
                    Spacer()
                }
            }
            if !appState.channelStore.retryQueue.isEmpty {
                Section("Видео в ожидании субтитров") {
                    Text("В ожидании: \(appState.channelStore.retryQueue.count). YouTube не сразу публикует автосабы — мы проверим эти видео ещё несколько раз в ближайшие сутки.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
    }

    private var aboutTab: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("yt-kb").font(.title3.bold())
            Text("YouTube → Markdown база знаний")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            Group {
                row("Версия", appVersion)
                row("Логи", "~/Library/Logs/yt-kb/yt-kb.log", isPath: true)
                row("State", "~/Library/Application Support/yt-kb/state.json", isPath: true)
            }

            HStack(spacing: 8) {
                Button("Открыть лог в Console") {
                    let log = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
                        .appendingPathComponent("Logs/yt-kb/yt-kb.log")
                    NSWorkspace.shared.open(log)
                }
                Button("Показать onboarding ещё раз") { resetOnboarding() }
            }

            Divider()
                .padding(.vertical, 8)

            updateSection

            Divider()
                .padding(.vertical, 8)

            Text("Удаление").font(.headline)
            Text("Уберёт настройки и список каналов. Папку с транскриптами спросим отдельно.")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack {
                Button("Удалить yt-kb…", role: .destructive) {
                    runUninstall()
                }
                Spacer()
            }

            Spacer()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func row(_ key: String, _ value: String, isPath: Bool = false) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(key + ":")
                .frame(width: 70, alignment: .trailing)
                .foregroundStyle(.secondary)
                .font(.caption)
            Text(value)
                .font(isPath ? .caption.monospaced() : .caption)
                .foregroundStyle(isPath ? .secondary : .primary)
                .textSelection(.enabled)
        }
    }

    private func runUninstall() {
        let confirm = NSAlert()
        confirm.messageText = "Удалить yt-kb?"
        confirm.informativeText = "Будут удалены настройки, список каналов и логи. После этого нужно будет перетащить приложение из «Программы» в Корзину."
        confirm.alertStyle = .warning
        confirm.addButton(withTitle: "Удалить")
        confirm.addButton(withTitle: "Отмена")
        confirm.accessoryView = NSView(frame: NSRect(x: 0, y: 0, width: 480, height: 0))
        guard confirm.runModal() == .alertFirstButtonReturn else { return }

        // Ask about KB folder separately
        var removeKB = false
        if let kb = appState.settings.kbDirectory {
            let kbAlert = NSAlert()
            kbAlert.messageText = "Удалить также папку с транскриптами?"
            kbAlert.informativeText = "\(kb.path)\n\nОбычно её оставляют — заново скачивать видео долго."
            kbAlert.alertStyle = .warning
            kbAlert.addButton(withTitle: "Оставить")
            kbAlert.addButton(withTitle: "Удалить")
            kbAlert.accessoryView = NSView(frame: NSRect(x: 0, y: 0, width: 480, height: 0))
            removeKB = (kbAlert.runModal() == .alertSecondButtonReturn)
        }

        let kbToRemove = removeKB ? appState.settings.kbDirectory : nil
        let bundleId = Bundle.main.bundleIdentifier ?? "io.yt-kb.app"

        Task {
            await PollingCoordinator.shared.cancel()

            await MainActor.run {
                let fm = FileManager.default
                let home = URL(fileURLWithPath: NSHomeDirectory())
                let library = home.appendingPathComponent("Library")

                // App-managed dirs (these we wrote ourselves)
                try? fm.removeItem(at: library.appendingPathComponent("Application Support/yt-kb"))
                try? fm.removeItem(at: library.appendingPathComponent("Logs/yt-kb"))

                // System-managed dirs (macOS may have created them automatically)
                let systemDirs: [String] = [
                    "Caches/\(bundleId)",
                    "Saved Application State/\(bundleId).savedState",
                    "HTTPStorages/\(bundleId)",
                    "WebKit/\(bundleId)",
                    "Containers/\(bundleId)",
                    "Application Scripts/\(bundleId)"
                ]
                for sub in systemDirs {
                    try? fm.removeItem(at: library.appendingPathComponent(sub))
                }

                UserDefaults.standard.removePersistentDomain(forName: bundleId)
                UserDefaults.standard.synchronize()

                if let kb = kbToRemove {
                    let started = kb.startAccessingSecurityScopedResource()
                    try? fm.removeItem(at: kb)
                    if started { kb.stopAccessingSecurityScopedResource() }
                }

                // Detached cleanup — runs after our process exits so cfprefsd
                // doesn't re-flush the plist file we just removed.
                let prefsPath = library.appendingPathComponent("Preferences/\(bundleId).plist").path
                let cleanupScript = """
                sleep 2
                /bin/rm -f '\(prefsPath)'
                /bin/rm -rf '\(library.path)/Caches/\(bundleId)'
                /bin/rm -rf '\(library.path)/Saved Application State/\(bundleId).savedState'
                /bin/rm -rf '\(library.path)/HTTPStorages/\(bundleId)'
                /bin/rm -rf '\(library.path)/WebKit/\(bundleId)'
                """
                let task = Process()
                task.executableURL = URL(fileURLWithPath: "/bin/sh")
                task.arguments = ["-c", cleanupScript]
                try? task.run()

                let final = NSAlert()
                final.messageText = "Готово"
                final.informativeText = "Откройте «Программы» и перетащите YTKB в Корзину — это завершит удаление."
                final.addButton(withTitle: "Открыть Программы и закрыть")
                final.accessoryView = NSView(frame: NSRect(x: 0, y: 0, width: 420, height: 0))
                final.runModal()

                // Open /Applications in Finder so user can drag the .app to trash
                NSWorkspace.shared.open(URL(fileURLWithPath: "/Applications"))
                NSApp.terminate(nil)
            }
        }
    }

    private func resetOnboarding() {
        UserDefaults.standard.set(false, forKey: "onboardingCompleted")
        appState.settings.onboardingCompleted = false
        appState.needsOnboarding = true
        NotificationCenter.default.post(name: .ytkbShowOnboarding, object: nil)
    }

    @ViewBuilder
    private var updateSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Обновления").font(.headline)
            Toggle("Автоматически проверять обновления", isOn: Binding(
                get: { appState.settings.autoUpdateEnabled },
                set: { appState.settings.setAutoUpdateEnabled($0) }
            ))
            Text("Проверка идёт раз в 6 часов через GitHub Releases API. Репо публичный — токен не нужен.")
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack(spacing: 8) {
                Button("Проверить сейчас") {
                    appState.checkForUpdate(manual: true)
                }
                .disabled(appState.isCheckingUpdate)
                if appState.isCheckingUpdate {
                    ProgressView()
                        .controlSize(.small)
                    Text("Проверяю обновления…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else if let update = appState.availableUpdate {
                    Text("Доступна версия \(update.version)")
                        .font(.caption)
                        .foregroundStyle(.green)
                } else if let error = appState.updateCheckError {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .lineLimit(2)
                } else if let checkedAt = appState.lastUpdateCheckAt {
                    Text("Версия \(appVersion) — актуальная (проверено: \(Self.timeFormatter.string(from: checkedAt)))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Text("Версия \(appVersion) — актуальная")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            // When an update is detected (manually or by the 6h auto-check),
            // the menu-bar popover shows an "install + restart" button — but
            // most users live in this Settings window when checking, so
            // duplicate the install affordance here. Otherwise users see
            // "Доступна версия 1.7.2" and have nothing to click.
            if let update = appState.availableUpdate {
                updateInstallRow(update)
            }
        }
    }

    @ViewBuilder
    private func updateInstallRow(_ update: AppUpdate) -> some View {
        if let progress = appState.updateInstallProgress {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(progress.phase)
                        .font(.caption)
                        .foregroundStyle(.secondary)
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
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.regular)
        }
    }

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.timeStyle = .short
        f.dateStyle = .none
        return f
    }()

    private var kbImportInfoPopover: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Формат KB-папки").font(.headline)
            Text("Сканирует выбранную папку и подхватывает каналы из подпапок верхнего уровня.")
                .font(.caption)
            Text("На канал нужно минимум одно `.md`-видео. Чтобы определить имя и URL, приложение читает либо `index.md` (`# Имя канала` + строка `**Канал:** <url>`), либо YAML-frontmatter в любом видеофайле канала с полями `channel:` и `channel_url:`.")
                .font(.caption)
            Text("Имя самой подпапки роли не играет — метаданные читаются изнутри файлов, поэтому папки, оставшиеся от прежних версий, тоже подхватятся.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(12)
        .frame(width: 360, alignment: .leading)
    }

    private var jsonImportInfoPopover: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Формат JSON").font(.headline)
            Text("Файл — массив объектов. Поля каждого:")
                .font(.caption)
            VStack(alignment: .leading, spacing: 2) {
                Text("• `url` — URL канала на YouTube (обязательно)").font(.caption)
                Text("• `name` — отображаемое имя (обязательно)").font(.caption)
                Text("• `channel_id` — ID канала `UCxxxxx…` (опционально)").font(.caption)
                Text("• `enabled` — bool, по умолчанию `true` (опционально)").font(.caption)
            }
            Text("Дубликаты по `url` пропускаются. Формат симметричен с экспортом — выгрузить пример можно через «Экспортировать список каналов в JSON…».")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(12)
        .frame(width: 360, alignment: .leading)
    }

    private var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.1.0"
    }

    private func pickKBDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Выбрать"
        panel.message = "Выберите папку для базы знаний"
        if let current = appState.settings.kbDirectory {
            panel.directoryURL = current
        } else {
            panel.directoryURL = appState.settings.defaultKBDirectory()
        }
        guard panel.runModal() == .OK, let newURL = panel.url else { return }

        let oldURL = appState.settings.kbDirectory
        // Offer to migrate if old dir had content and new dir is different
        if let oldURL, oldURL != newURL {
            let started = oldURL.startAccessingSecurityScopedResource()
            let hasContent = KBMigrator.hasContent(at: oldURL)
            if started { oldURL.stopAccessingSecurityScopedResource() }

            if hasContent {
                let alert = NSAlert()
                alert.messageText = "Что делать с текущей базой?"
                alert.informativeText = "В \(oldURL.lastPathComponent) уже есть транскрипты. Перенести их в новую папку или оставить там?"
                alert.alertStyle = .informational
                alert.addButton(withTitle: "Переместить")
                alert.addButton(withTitle: "Оставить там")
                alert.addButton(withTitle: "Отмена")
                let response = alert.runModal()
                switch response {
                case .alertFirstButtonReturn:
                    do {
                        try appState.settings.setKBDirectory(newURL)
                        runMigration(from: oldURL, to: newURL)
                        rediscover()
                    } catch {
                        Logger.shared.error("setKBDirectory failed: \(error)")
                    }
                    return
                case .alertSecondButtonReturn:
                    do {
                        try appState.settings.setKBDirectory(newURL)
                        rediscover()
                    } catch {
                        Logger.shared.error("setKBDirectory failed: \(error)")
                    }
                    return
                default:
                    return  // Cancel
                }
            }
        }

        // No migration needed
        do {
            try appState.settings.setKBDirectory(newURL)
            rediscover()
        } catch {
            Logger.shared.error("setKBDirectory failed: \(error)")
        }
    }

    private func runMigration(from oldURL: URL, to newURL: URL) {
        let oldStarted = oldURL.startAccessingSecurityScopedResource()
        defer { if oldStarted { oldURL.stopAccessingSecurityScopedResource() } }
        let newStarted = newURL.startAccessingSecurityScopedResource()
        defer { if newStarted { newURL.stopAccessingSecurityScopedResource() } }

        Logger.shared.info("KB migration: \(oldURL.path) → \(newURL.path)")
        let report = KBMigrator.migrate(from: oldURL, to: newURL)
        Logger.shared.info("KB migration done: copied=\(report.copied) skipped=\(report.skipped) failed=\(report.failed.count) bytes=\(report.bytesCopied)")

        let alert = NSAlert()
        alert.messageText = "Перенос завершён"
        var info = "Перемещено: \(report.copied) файлов (~\(formatBytes(report.bytesCopied)))"
        if report.skipped > 0 { info += "\nПропущено (уже было): \(report.skipped)" }
        if !report.failed.isEmpty {
            info += "\nНе удалось перенести: \(report.failed.count) файлов. Подробности в логе."
        }
        alert.informativeText = info
        alert.alertStyle = report.failed.isEmpty ? .informational : .warning
        alert.runModal()
    }

    private func formatBytes(_ bytes: Int64) -> String {
        let units = ["B", "KB", "MB", "GB"]
        var value = Double(bytes)
        var idx = 0
        while value >= 1024, idx < units.count - 1 {
            value /= 1024
            idx += 1
        }
        return String(format: "%.1f %@", value, units[idx])
    }

    private func rediscover() {
        let candidates = appState.discoverNewChannels()
        if candidates.isEmpty {
            let alert = NSAlert()
            alert.messageText = "Нет новых каналов"
            alert.informativeText = "В выбранной папке не найдено каналов, которых ещё нет в списке отслеживаемых."
            alert.alertStyle = .informational
            alert.runModal()
            return
        }
        let alert = NSAlert()
        alert.messageText = "Найдено \(candidates.count) канал(ов) в KB"
        let preview = candidates.prefix(5).map(\.name).joined(separator: ", ")
        let extra = candidates.count > 5 ? " и ещё \(candidates.count - 5)" : ""
        alert.informativeText = "Добавить на отслеживание?\n\(preview)\(extra)"
        alert.addButton(withTitle: "Добавить все")
        alert.addButton(withTitle: "Отмена")
        if alert.runModal() == .alertFirstButtonReturn {
            appState.adoptDiscovered(candidates)
        }
    }

    private func exportChannels() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "yt-kb-channels.json"
        panel.title = "Экспорт каналов"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let payload = appState.channelStore.channels.map { ch -> [String: Any] in
                var dict: [String: Any] = ["url": ch.url, "name": ch.name, "enabled": ch.enabled]
                if let cid = ch.channelId { dict["channel_id"] = cid }
                return dict
            }
            let data = try JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys])
            try data.write(to: url)
        } catch {
            let alert = NSAlert()
            alert.messageText = "Не удалось экспортировать"
            alert.informativeText = "\(error)"
            alert.alertStyle = .warning
            alert.runModal()
        }
    }

    private func importChannels() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.title = "Импорт каналов"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let data = try Data(contentsOf: url)
            guard let array = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
                throw NSError(domain: "YTKB", code: 1, userInfo: [NSLocalizedDescriptionKey: "Ожидается массив каналов"])
            }
            // Discover once: if any imported channel already has a folder on
            // disk (from a prior install), reuse its name instead of letting
            // the first poll create a duplicate clean-slug sibling.
            var existingByURL: [String: String] = [:]
            if let kb = appState.settings.kbDirectory {
                let started = kb.startAccessingSecurityScopedResource()
                for d in AutoDiscovery.discover(in: kb) {
                    existingByURL[KBConsolidator.normalizeURL(d.url)] = d.folderName
                }
                if started { kb.stopAccessingSecurityScopedResource() }
            }

            var added = 0
            for entry in array {
                guard let url = entry["url"] as? String, !url.isEmpty,
                      let name = entry["name"] as? String, !name.isEmpty else { continue }
                if appState.channelStore.channels.contains(where: { $0.url == url }) { continue }
                let ch = TrackedChannel(
                    url: url,
                    channelId: entry["channel_id"] as? String,
                    name: name,
                    addedAt: Date(),
                    lastPolledAt: nil,
                    lastPollStatus: nil,
                    lastPollError: nil,
                    enabled: (entry["enabled"] as? Bool) ?? true,
                    folderName: existingByURL[KBConsolidator.normalizeURL(url)]
                )
                appState.channelStore.addChannel(ch)
                added += 1
            }
            let alert = NSAlert()
            alert.messageText = "Импортировано: \(added)"
            alert.informativeText = added > 0 ? "Добавлено \(added) новых каналов на отслеживание." : "Все каналы из файла уже есть в списке."
            alert.alertStyle = .informational
            alert.runModal()
        } catch {
            let alert = NSAlert()
            alert.messageText = "Не удалось импортировать"
            alert.informativeText = "\(error)"
            alert.alertStyle = .warning
            alert.runModal()
        }
    }
}

private struct LanguagePriorityList: View {
    @ObservedObject var appState: AppState
    @State private var selectedCode: String = ""
    @State private var draggingToken: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(appState.settings.languagePriority.enumerated()), id: \.element) { idx, token in
                row(idx: idx, token: token)
            }
            Divider().padding(.vertical, 4)
            HStack(spacing: 8) {
                Text("Добавить язык")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Picker("", selection: $selectedCode) {
                    Text("Выберите язык").tag("")
                    ForEach(availableLanguages) { lang in
                        Text(lang.displayName).tag(lang.code)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .frame(minWidth: 220, maxWidth: .infinity)
                Button("Добавить") { addSelected() }
                    .disabled(selectedCode.isEmpty)
            }
        }
    }

    @ViewBuilder
    private func row(idx: Int, token: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "line.3.horizontal")
                .foregroundStyle(.secondary)
                .help("Перетащите для изменения порядка")
            Text("\(idx + 1).")
                .foregroundStyle(.secondary)
                .frame(width: 24, alignment: .trailing)
            Text(displayName(for: token))
                .frame(maxWidth: .infinity, alignment: .leading)
            Button {
                remove(idx)
            } label: { Image(systemName: "minus.circle") }
                .buttonStyle(.borderless)
                .disabled(appState.settings.languagePriority.count <= 1)
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
        .opacity(draggingToken == token ? 0.4 : 1.0)
        .onDrag {
            draggingToken = token
            return NSItemProvider(object: token as NSString)
        }
        .onDrop(
            of: [.text],
            delegate: LanguageDropDelegate(
                target: token,
                dragging: $draggingToken,
                list: appState.settings.languagePriority,
                commit: { appState.settings.setLanguagePriority($0) }
            )
        )
    }

    /// Languages from the curated list that aren't already in the priority chain.
    private var availableLanguages: [Languages.Entry] {
        let alreadyAdded = Set(appState.settings.languagePriority.map { $0.lowercased() })
        return Languages.common.filter { !alreadyAdded.contains($0.code.lowercased()) }
    }

    private func addSelected() {
        guard !selectedCode.isEmpty else { return }
        var list = appState.settings.languagePriority
        if !list.contains(selectedCode) {
            list.append(selectedCode)
            appState.settings.setLanguagePriority(list)
        }
        selectedCode = ""
    }

    private func displayName(for token: String) -> String {
        switch token {
        case "@original": return "Язык оригинала видео"
        case "@english": return "Английский"
        case "@any": return "Любой доступный"
        default: return Languages.displayName(for: token)
        }
    }

    private func remove(_ idx: Int) {
        var list = appState.settings.languagePriority
        guard list.count > 1 else { return }
        list.remove(at: idx)
        appState.settings.setLanguagePriority(list)
    }
}

private struct LanguageDropDelegate: DropDelegate {
    let target: String
    @Binding var dragging: String?
    let list: [String]
    let commit: ([String]) -> Void

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }

    func dropEntered(info: DropInfo) {
        guard let source = dragging, source != target,
              let from = list.firstIndex(of: source),
              let to = list.firstIndex(of: target) else { return }
        var newList = list
        newList.remove(at: from)
        newList.insert(source, at: to)
        withAnimation(.easeInOut(duration: 0.15)) {
            commit(newList)
        }
    }

    func performDrop(info: DropInfo) -> Bool {
        dragging = nil
        return true
    }
}
