import SwiftUI
import AppKit

struct SettingsView: View {
    @ObservedObject var appState: AppState

    var body: some View {
        TabView {
            generalTab
                .tabItem { Label("Базовые", systemImage: "gear") }
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
        }
        .formStyle(.grouped)
    }

    private var advancedTab: some View {
        Form {
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

    private var aboutTab: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("yt-kb · Phase 1 MVP").font(.headline)
            Text("YouTube → Markdown база знаний").font(.subheadline).foregroundStyle(.secondary)
            Spacer().frame(height: 12)
            Text("Версия приложения: \(appVersion)")
            Text("Логи: ~/Library/Logs/yt-kb/yt-kb.log").font(.caption).foregroundStyle(.secondary)
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
            } catch {
                Logger.shared.error("setKBDirectory failed: \(error)")
            }
        }
    }
}
