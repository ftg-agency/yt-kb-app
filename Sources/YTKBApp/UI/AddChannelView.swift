import SwiftUI

struct AddChannelView: View {
    @ObservedObject var appState: AppState
    @Binding var isPresented: Bool

    @State private var url: String = ""
    @State private var resolving = false
    @State private var error: String?
    @State private var resolvedName: String?
    @State private var resolvedChannelId: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Добавить канал").font(.headline)

            Text("Вставьте URL канала (например `https://www.youtube.com/@handle`).")
                .font(.caption)
                .foregroundStyle(.secondary)

            TextField("https://www.youtube.com/@handle", text: $url)
                .textFieldStyle(.roundedBorder)
                .disabled(resolving)

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
                if resolvedName != nil {
                    Button("Добавить") { save() }
                        .keyboardShortcut(.defaultAction)
                } else {
                    Button("Проверить URL") { resolve() }
                        .disabled(resolving || url.trimmingCharacters(in: .whitespaces).isEmpty)
                        .keyboardShortcut(.defaultAction)
                }
            }
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
    }

    private func resolve() {
        let raw = url.trimmingCharacters(in: .whitespaces)
        error = nil
        resolvedName = nil
        resolvedChannelId = nil
        resolving = true

        Task {
            defer { Task { @MainActor in resolving = false } }
            do {
                let resolver = ChannelResolver(
                    runner: YTDLPRunner.shared,
                    settings: appState.settings
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
    }
}
