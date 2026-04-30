import SwiftUI
import AppKit

struct OnboardingView: View {
    @ObservedObject var appState: AppState
    var onFinish: () -> Void

    @State private var step: Int = 0
    @State private var discovered: [DiscoveredChannel] = []
    @State private var hasCheckedDiscovery = false

    var body: some View {
        VStack(spacing: 16) {
            Text("Добро пожаловать в yt-kb").font(.title2.bold())
            Text("Шаг \(step + 1) из 3").font(.caption).foregroundStyle(.secondary)

            Group {
                switch step {
                case 0: kbStep
                case 1: cookiesStep
                default: doneStep
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            HStack {
                if step > 0 {
                    Button("Назад") { step -= 1 }
                }
                Spacer()
                Button(step < 2 ? "Дальше" : "Готово") {
                    if step == 0 {
                        runDiscovery()
                    }
                    if step < 2 {
                        step += 1
                    } else {
                        if !discovered.isEmpty {
                            appState.adoptDiscovered(discovered)
                        }
                        appState.settings.markOnboardingComplete()
                        appState.needsOnboarding = false
                        onFinish()
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(step == 0 && appState.settings.kbDirectory == nil)
            }
        }
        .padding(20)
        .frame(width: 540, height: 420)
    }

    private var kbStep: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Где хранить базу знаний?").font(.headline)
            Text("Скачанные транскрипты будут лежать в этой папке. Каждый канал получит свою подпапку с index.md и видео-файлами.")
                .font(.callout)
                .foregroundStyle(.secondary)

            HStack {
                Text(appState.settings.kbDirectory?.path ?? appState.settings.defaultKBDirectory().path)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .foregroundStyle(appState.settings.kbDirectory == nil ? .tertiary : .primary)
                Spacer()
                Button("Выбрать…") { pickKB() }
            }
            .padding(8)
            .background(Color.secondary.opacity(0.1))
            .cornerRadius(6)

            Button("Использовать дефолтную (\(appState.settings.defaultKBDirectory().path))") {
                useDefault()
            }
            .controlSize(.small)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var cookiesStep: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Cookies для YouTube").font(.headline)
            Text("YouTube блокирует автоматические запросы без авторизации. Скрипт берёт cookies из выбранного браузера.")
                .font(.callout)
                .foregroundStyle(.secondary)

            Picker("Браузер:", selection: Binding(
                get: { appState.settings.browser },
                set: { appState.settings.setBrowser($0) }
            )) {
                ForEach(Settings.BrowserChoice.allCases) { c in
                    Text(c.displayName).tag(c)
                }
            }

            Text("ⓘ При первом запросе macOS попросит разрешение на доступ к ключам \"Chrome Safe Storage\" (для Chrome) — нажмите \"Разрешать всегда\".")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(8)
                .background(Color.secondary.opacity(0.1))
                .cornerRadius(6)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var doneStep: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Готово!").font(.headline)
            if !discovered.isEmpty {
                Text("В выбранной папке найдено \(discovered.count) канал(ов):")
                    .font(.callout)
                ScrollView {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(discovered, id: \.url) { ch in
                            HStack {
                                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                                Text(ch.name).font(.callout)
                                Spacer()
                                Text("\(ch.videoCount) видео")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                .frame(maxHeight: 160)
                Text("Они будут добавлены на отслеживание.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Text("Иконка yt-kb появилась в menu bar — кликните по ней чтобы добавить первый канал.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                HStack {
                    Image(systemName: "text.book.closed.fill")
                    Text("← такая иконка").foregroundStyle(.secondary)
                }
                .padding(.top, 8)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func runDiscovery() {
        guard !hasCheckedDiscovery else { return }
        hasCheckedDiscovery = true
        discovered = appState.discoverNewChannels()
    }

    private func pickKB() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Выбрать"
        panel.directoryURL = appState.settings.defaultKBDirectory()
        if panel.runModal() == .OK, let url = panel.url {
            do {
                try appState.settings.setKBDirectory(url)
                hasCheckedDiscovery = false
            } catch {
                Logger.shared.error("Onboarding: setKBDirectory failed: \(error)")
            }
        }
    }

    private func useDefault() {
        let url = appState.settings.defaultKBDirectory()
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        do {
            try appState.settings.setKBDirectory(url)
            hasCheckedDiscovery = false
        } catch {
            Logger.shared.error("Onboarding: useDefault failed: \(error)")
        }
    }
}
