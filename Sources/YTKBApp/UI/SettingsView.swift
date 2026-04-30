import SwiftUI
import AppKit

struct SettingsView: View {
    @ObservedObject var appState: AppState

    var body: some View {
        TabView {
            generalTab
                .tabItem { Label("Базовые", systemImage: "gear") }
            scheduleTab
                .tabItem { Label("Расписание", systemImage: "clock") }
            advancedTab
                .tabItem { Label("Дополнительно", systemImage: "wrench.and.screwdriver") }
            aboutTab
                .tabItem { Label("О приложении", systemImage: "info.circle") }
        }
        .padding(20)
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
                Picker("Частота", selection: Binding(
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
            Section("Каналы") {
                Button("Импортировать каналы из существующей KB-папки") { rediscover() }
                if !appState.channelStore.retryQueue.isEmpty {
                    Text("В retry-очереди: \(appState.channelStore.retryQueue.count) видео")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
    }

    private var aboutTab: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("yt-kb").font(.headline)
            Text("YouTube → Markdown база знаний").font(.subheadline).foregroundStyle(.secondary)
            Spacer().frame(height: 12)
            Text("Версия приложения: \(appVersion)")
            Text("Логи: ~/Library/Logs/yt-kb/yt-kb.log").font(.caption).foregroundStyle(.secondary)
            Text("State: ~/Library/Application Support/yt-kb/state.json").font(.caption).foregroundStyle(.secondary)
            Spacer().frame(height: 8)
            Button("Открыть лог в Console") {
                let log = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
                    .appendingPathComponent("Logs/yt-kb/yt-kb.log")
                NSWorkspace.shared.open(log)
            }
            Spacer()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
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
        if panel.runModal() == .OK, let url = panel.url {
            do {
                try appState.settings.setKBDirectory(url)
                rediscover()
            } catch {
                Logger.shared.error("setKBDirectory failed: \(error)")
            }
        }
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
}

private struct LanguagePriorityList: View {
    @ObservedObject var appState: AppState
    @State private var newToken: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
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
            HStack {
                TextField("ru / fr-FR / @any...", text: $newToken)
                    .textFieldStyle(.roundedBorder)
                Button("Добавить") {
                    let trimmed = newToken.trimmingCharacters(in: .whitespaces)
                    guard !trimmed.isEmpty else { return }
                    var list = appState.settings.languagePriority
                    if !list.contains(trimmed) {
                        list.append(trimmed)
                        appState.settings.setLanguagePriority(list)
                    }
                    newToken = ""
                }
            }
        }
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
