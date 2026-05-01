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
                        isPollingThis: appState.pollingChannelURL == channel.url,
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
                        onRemove: { appState.channelStore.removeChannel(url: channel.url) }
                    )
                    Divider()
                }
            }
        }
    }

    private func reindexAll() {
        let alert = NSAlert()
        alert.messageText = "Переиндексировать все каналы?"
        alert.informativeText = "Каналы будут помечены как «не опрашивались» и пройдут полный цикл проверки. Уже скачанные транскрипты не будут перезаписаны (idempotency по video_id). Подходит когда нужно дочистить пропущенное и заново посмотреть retry-очередь."
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
            Section("Cookies") {
                Picker("Браузер", selection: Binding(
                    get: { appState.settings.browser },
                    set: { appState.settings.setBrowser($0) }
                )) {
                    ForEach(Settings.BrowserChoice.allCases) { choice in
                        Text(choice.displayName).tag(choice)
                    }
                }
                Text("yt-dlp возьмёт cookies из выбранного браузера. macOS попросит разрешение на доступ к ключам один раз.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("Уведомления") {
                Toggle("Показывать нотификации (новые видео, ошибки)", isOn: Binding(
                    get: { appState.settings.notificationsEnabled },
                    set: { appState.settings.setNotificationsEnabled($0) }
                ))
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
            Section("Энергосбережение") {
                Toggle("Не давать Mac засыпать во время индексации", isOn: Binding(
                    get: { appState.settings.preventSleepDuringPoll },
                    set: { appState.settings.setPreventSleepDuringPoll($0) }
                ))
                Text("Большой канал на 5000+ видео индексируется несколько часов. Если Mac уходит в сон посередине — индексация прерывается до следующего scheduled-опроса. Когда галочка стоит — приложение удерживает систему от idle-сна на время активной проверки (через ProcessInfo.beginActivity), и отпускает сразу как закончит.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("Когда Mac на батарее и закрыт крышкой — это не работает (macOS forced sleep). NSBackgroundActivityScheduler пробует разбудить систему через Power Nap при подключении к питанию.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("Тихие часы") {
                Toggle("Не опрашивать в выбранные часы", isOn: Binding(
                    get: { appState.settings.quietHoursEnabled },
                    set: {
                        appState.settings.setQuietHours(
                            enabled: $0,
                            start: appState.settings.quietHoursStart,
                            end: appState.settings.quietHoursEnd
                        )
                    }
                ))
                if appState.settings.quietHoursEnabled {
                    HStack {
                        Stepper("С \(appState.settings.quietHoursStart):00", value: Binding(
                            get: { appState.settings.quietHoursStart },
                            set: {
                                appState.settings.setQuietHours(
                                    enabled: true,
                                    start: $0,
                                    end: appState.settings.quietHoursEnd
                                )
                            }
                        ), in: 0...23)
                        Stepper("До \(appState.settings.quietHoursEnd):00", value: Binding(
                            get: { appState.settings.quietHoursEnd },
                            set: {
                                appState.settings.setQuietHours(
                                    enabled: true,
                                    start: appState.settings.quietHoursStart,
                                    end: $0
                                )
                            }
                        ), in: 0...23)
                    }
                }
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
                Text("Помогает обходить bot-detection при массовом скачивании.")
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
                Button("Импортировать каналы из существующей KB-папки") { rediscover() }
                Button("Экспортировать список каналов в JSON…") { exportChannels() }
                    .disabled(appState.channelStore.channels.isEmpty)
                Button("Импортировать каналы из JSON…") { importChannels() }
            }
            if !appState.channelStore.retryQueue.isEmpty {
                Section("Retry-очередь") {
                    Text("В очереди: \(appState.channelStore.retryQueue.count) видео без субтитров — будут повторно проверены автоматически (см. §retry).")
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

            Text("Удаление").font(.headline)
            Text("Удалит state.json, логи и UserDefaults. После этого приложение закроется и его нужно будет перетащить в корзину вручную (мы не можем удалить приложение пока оно запущено).")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack {
                Button("Удалить все данные приложения…", role: .destructive) {
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
        confirm.messageText = "Удалить все данные yt-kb?"
        confirm.informativeText = """
        Будут удалены:
        • ~/Library/Application Support/yt-kb (state.json)
        • ~/Library/Logs/yt-kb (логи)
        • ~/Library/Preferences/io.yt-kb.app.plist (настройки)
        • ~/Library/Caches/io.yt-kb.app
        • ~/Library/Saved Application State/io.yt-kb.app.savedState
        • ~/Library/HTTPStorages/io.yt-kb.app
        • ~/Library/WebKit/io.yt-kb.app

        После этого спросим отдельно про папку с транскриптами.
        """
        confirm.alertStyle = .warning
        confirm.addButton(withTitle: "Удалить")
        confirm.addButton(withTitle: "Отмена")
        guard confirm.runModal() == .alertFirstButtonReturn else { return }

        // Ask separately about KB folder (user's actual data)
        var removeKB = false
        if let kb = appState.settings.kbDirectory {
            let kbAlert = NSAlert()
            kbAlert.messageText = "Удалить и папку с транскриптами?"
            kbAlert.informativeText = "\(kb.path)\n\nЭто твои сохранённые транскрипты — обычно их хочется оставить, потому что заново качать долго. По умолчанию папку оставляем."
            kbAlert.alertStyle = .warning
            kbAlert.addButton(withTitle: "Оставить папку")
            kbAlert.addButton(withTitle: "Удалить вместе с папкой")
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

                // 1. App-managed dirs (these we wrote ourselves)
                try? fm.removeItem(at: library.appendingPathComponent("Application Support/yt-kb"))
                try? fm.removeItem(at: library.appendingPathComponent("Logs/yt-kb"))

                // 2. System-managed dirs (macOS may have created them automatically)
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

                // 3. UserDefaults — clear in-memory state
                UserDefaults.standard.removePersistentDomain(forName: bundleId)
                UserDefaults.standard.synchronize()

                // 4. KB folder (user's data) — only if explicitly opted in
                if let kb = kbToRemove {
                    let started = kb.startAccessingSecurityScopedResource()
                    try? fm.removeItem(at: kb)
                    if started { kb.stopAccessingSecurityScopedResource() }
                }

                // 5. Defer plist file deletion to after our process exits.
                // cfprefsd writes the plist back on app termination. We need the
                // file deleted AFTER the daemon stops caring about us — so we
                // detach a shell that sleeps 2s and then rm-rf's the prefs plist
                // and re-attempts the system dirs in case cfprefsd recreated
                // anything mid-shutdown.
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
                // Detach from parent: don't wait, don't pipe.
                try? task.run()

                // 6. Tell user what to do next, then quit.
                let final = NSAlert()
                final.messageText = "Данные удалены"
                final.informativeText = "Все служебные файлы yt-kb удаляются. Сейчас приложение закроется — после этого перетащите YTKB.app в Корзину чтобы завершить удаление.\n\nЕсли используете AppCleaner и в нём останется один файл — это нормально, он удалится через 2 секунды после закрытия приложения."
                final.runModal()
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
                    enabled: (entry["enabled"] as? Bool) ?? true
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
    @State private var newToken: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(appState.settings.languagePriority.enumerated()), id: \.offset) { idx, token in
                HStack(spacing: 6) {
                    Text("\(idx + 1).")
                        .foregroundStyle(.secondary)
                        .frame(width: 24, alignment: .trailing)
                    Text(displayName(for: token))
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Button {
                        moveUp(idx)
                    } label: { Image(systemName: "chevron.up") }
                        .buttonStyle(.borderless)
                        .disabled(idx == 0)
                    Button {
                        moveDown(idx)
                    } label: { Image(systemName: "chevron.down") }
                        .buttonStyle(.borderless)
                        .disabled(idx == appState.settings.languagePriority.count - 1)
                    Button {
                        remove(idx)
                    } label: { Image(systemName: "minus.circle") }
                        .buttonStyle(.borderless)
                        .disabled(appState.settings.languagePriority.count <= 1)
                }
                .padding(.vertical, 2)
            }
            Divider().padding(.vertical, 4)
            VStack(alignment: .leading, spacing: 4) {
                Text("Добавить свой код языка")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HStack(spacing: 8) {
                    TextField("например ru или fr-FR", text: $newToken)
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: .infinity)
                        .onSubmit { addToken() }
                    Button("Добавить") { addToken() }
                        .disabled(newToken.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
    }

    private func addToken() {
        let trimmed = newToken.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        var list = appState.settings.languagePriority
        if !list.contains(trimmed) {
            list.append(trimmed)
            appState.settings.setLanguagePriority(list)
        }
        newToken = ""
    }

    private func displayName(for token: String) -> String {
        switch token {
        case "@original": return "Язык оригинала видео"
        case "@english": return "Английский"
        case "@any": return "Любой доступный"
        default: return token
        }
    }

    private func moveUp(_ idx: Int) {
        guard idx > 0 else { return }
        var list = appState.settings.languagePriority
        list.swapAt(idx, idx - 1)
        appState.settings.setLanguagePriority(list)
    }

    private func moveDown(_ idx: Int) {
        var list = appState.settings.languagePriority
        guard idx < list.count - 1 else { return }
        list.swapAt(idx, idx + 1)
        appState.settings.setLanguagePriority(list)
    }

    private func remove(_ idx: Int) {
        var list = appState.settings.languagePriority
        guard list.count > 1 else { return }
        list.remove(at: idx)
        appState.settings.setLanguagePriority(list)
    }
}
