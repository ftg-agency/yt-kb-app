import SwiftUI
import AppKit

struct AddChannelView: View {
    @ObservedObject var appState: AppState
    @Binding var isPresented: Bool

    @State private var url: String = ""
    @State private var resolving = false
    @State private var error: String?
    @State private var resolvedName: String?
    @State private var resolvedChannelId: String?
    @FocusState private var urlFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Добавить канал").font(.headline)

            Text("Вставьте URL канала (например `https://www.youtube.com/@handle`).")
                .font(.caption)
                .foregroundStyle(.secondary)

            TextField("https://www.youtube.com/@handle", text: $url)
                .textFieldStyle(.roundedBorder)
                .focused($urlFocused)
                .disabled(resolving)
                .onSubmit {
                    if resolvedName == nil {
                        resolve()
                    } else {
                        save()
                    }
                }

            if let resolvedName {
                HStack {
                    Image(systemName: "checkmark.seal.fill").foregroundStyle(.green)
                    Text("Найден канал: \(resolvedName)")
                }
                .font(.callout)
            }

            if let error {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .lineLimit(3)
            }

            HStack {
                Spacer()
                Button("Отмена") { isPresented = false }
                    .keyboardShortcut(.cancelAction)
                if resolvedName != nil {
                    Button("Добавить") { save() }
                        .keyboardShortcut(.defaultAction)
                } else {
                    Button("Проверить URL") { resolve() }
                        .disabled(resolving || url.trimmingCharacters(in: .whitespaces).isEmpty)
                        .keyboardShortcut(.defaultAction)
                }
            }

            // Hidden Cmd+V handler — LSUIElement apps have no main menu, so the
            // standard Edit→Paste shortcut isn't wired up. We catch Cmd+V here
            // and replace the URL field with the pasteboard contents.
            // Right-click → Paste already works because that's a NSTextField context menu.
            Button("") {
                if let str = NSPasteboard.general.string(forType: .string) {
                    url = str.trimmingCharacters(in: .whitespacesAndNewlines)
                    urlFocused = true
                }
            }
            .keyboardShortcut("v", modifiers: .command)
            .opacity(0)
            .frame(width: 0, height: 0)
        }
        .padding(20)
        .frame(width: 460, height: 220)
        .overlay {
            if resolving {
                ProgressView("Резолвлю канал через yt-dlp…")
                    .padding(20)
                    .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 8))
            }
        }
        .onAppear {
            // Defer focus so the sheet has time to settle into the responder chain
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                urlFocused = true
                // If clipboard already has a YouTube URL, pre-fill it as a hint
                if url.isEmpty,
                   let candidate = NSPasteboard.general.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines),
                   candidate.contains("youtube.com") || candidate.contains("youtu.be") {
                    url = candidate
                }
            }
        }
    }

    private func resolve() {
        let raw = url.trimmingCharacters(in: .whitespaces)
        guard !raw.isEmpty else { return }
        error = nil
        resolvedName = nil
        resolvedChannelId = nil
        resolving = true

        let config = appState.settings.ytdlpConfig
        Task {
            defer { Task { @MainActor in resolving = false } }
            do {
                let resolver = ChannelResolver(
                    runner: YTDLPRunner.shared,
                    config: config
                )
                let result = try await resolver.resolveMetadata(channelURL: raw)
                await MainActor.run {
                    resolvedName = result.name
                    resolvedChannelId = result.channelId
                }
            } catch {
                await MainActor.run {
                    self.error = "\(error)"
                }
            }
        }
    }

    private func save() {
        guard let name = resolvedName else { return }
        let channel = TrackedChannel(
            url: url.trimmingCharacters(in: .whitespaces),
            channelId: resolvedChannelId,
            name: name,
            addedAt: Date(),
            lastPolledAt: nil,
            lastPollStatus: nil,
            lastPollError: nil,
            enabled: true
        )
        appState.channelStore.addChannel(channel)
        isPresented = false
        Task { await PollingCoordinator.shared.pollOne(channel: channel, appState: appState) }
    }
}
