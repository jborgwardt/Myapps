import SwiftUI

struct ChatView: View {
    @EnvironmentObject private var app: AppModel
    @State private var messages: [ChatMessage] = []
    @State private var input = ""
    @State private var localModels: [OllamaLocalModel] = []
    @State private var isSending = false
    @State private var connectionOK = false
    @State private var statusText = "Ollama optional"
    @State private var sendTask: Task<Void, Never>?

    var body: some View {
        NavigationStack {
            ZStack {
                CursorTheme.background.ignoresSafeArea()

                VStack(spacing: 0) {
                    header
                    if messages.isEmpty {
                        emptyState
                    } else {
                        messageList
                    }
                    composer
                }
            }
            .toolbar(.hidden, for: .navigationBar)
            .task { await refresh() }
            .onDisappear {
                sendTask?.cancel()
                app.speechRecognizer.stop()
                app.ttsManager.stop()
            }
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 10) {
            HStack(spacing: 7) {
                Circle()
                    .fill(app.settings.isOllamaConfigured ? (connectionOK ? Color.green : Color.orange) : CursorTheme.secondaryText)
                    .frame(width: 6, height: 6)
                Text(app.settings.isOllamaConfigured ? app.settings.ollamaHost : "local")
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(CursorTheme.secondaryText)
                    .lineLimit(1)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .glassSurface(in: Capsule())

            Spacer()

            if !localModels.isEmpty {
                Menu {
                    ForEach(localModels) { model in
                        Button {
                            app.settings.selectedChatModel = model.name
                        } label: {
                            if app.settings.selectedChatModel == model.name {
                                Label(model.name, systemImage: "checkmark")
                            } else {
                                Text(model.name)
                            }
                        }
                    }
                } label: {
                    HStack(spacing: 5) {
                        Text(shortModelName)
                            .font(.system(.caption, design: .monospaced))
                            .lineLimit(1)
                        Image(systemName: "chevron.up.chevron.down")
                            .font(.system(size: 9, weight: .semibold))
                    }
                    .foregroundStyle(.primary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
                }
                .glassSurface(in: Capsule(), interactive: true)
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 10)
    }

    private var shortModelName: String {
        guard let name = app.settings.selectedChatModel, !name.isEmpty else { return "model" }
        // "dagbs/qwen2.5-coder-1.5b-…:latest" → "qwen2.5-coder-1.5b-…"
        let noOwner = name.split(separator: "/").last.map(String.init) ?? name
        let noTag = noOwner.split(separator: ":").first.map(String.init) ?? noOwner
        return noTag.count > 26 ? String(noTag.prefix(24)) + "…" : noTag
    }

    // MARK: Empty state

    private var emptyState: some View {
        VStack(spacing: 14) {
            Spacer()
            Image(systemName: "waveform")
                .font(.system(size: 34, weight: .light))
                .foregroundStyle(CursorTheme.secondaryText)
            Text(app.settings.isOllamaConfigured ? "Ask anything" : "Voice works on-device")
                .font(.title3.weight(.medium))
            Text(app.settings.isOllamaConfigured
                 ? "Replies stream from \(app.settings.ollamaHost) and can be spoken aloud."
                 : "Mic + TTS run locally. Connect an optional Ollama host in Settings for chat.")
                .font(.footnote)
                .foregroundStyle(CursorTheme.secondaryText)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 44)
            if !app.settings.isOllamaConfigured {
                Button("Configure Ollama") { app.selectedTab = .settings }
                    .glassButton()
                    .padding(.top, 4)
            }
            Spacer()
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: Messages

    private var messageList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 20) {
                    ForEach(messages) { message in
                        MessageBubble(message: message)
                            .id(message.id)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            }
            .scrollDismissesKeyboard(.interactively)
            .onChange(of: messages.count) { _, _ in
                if let last = messages.last {
                    withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
                }
            }
        }
    }

    // MARK: Composer

    private var composer: some View {
        VStack(spacing: 8) {
            if app.speechRecognizer.isRecording {
                HStack(spacing: 8) {
                    Image(systemName: "waveform")
                        .symbolEffect(.variableColor.iterative, options: .repeating)
                        .foregroundStyle(.red)
                    Text(app.speechRecognizer.transcript.isEmpty ? "Listening…" : app.speechRecognizer.transcript)
                        .font(.footnote)
                        .foregroundStyle(CursorTheme.secondaryText)
                        .lineLimit(2)
                    Spacer()
                }
                .padding(.horizontal, 20)
            }

            HStack(alignment: .bottom, spacing: 10) {
                HStack(alignment: .bottom, spacing: 8) {
                    TextField(
                        app.settings.isOllamaConfigured ? "Ask anything" : "Voice-only — add Ollama in Settings",
                        text: $input,
                        axis: .vertical
                    )
                    .textFieldStyle(.plain)
                    .lineLimit(1...5)
                    .padding(.leading, 16)
                    .padding(.vertical, 12)
                    .disabled(!app.settings.isOllamaConfigured)

                    Button {
                        Task {
                            await app.speechRecognizer.requestAuthorization()
                            if app.speechRecognizer.isRecording {
                                app.speechRecognizer.stop()
                                let text = app.speechRecognizer.consumeTranscript()
                                if !text.isEmpty { input = text }
                            } else {
                                app.speechRecognizer.start()
                            }
                        }
                    } label: {
                        Image(systemName: app.speechRecognizer.isRecording ? "mic.fill" : "mic")
                            .font(.system(size: 17, weight: .medium))
                            .foregroundStyle(app.speechRecognizer.isRecording ? Color.red : CursorTheme.secondaryText)
                            .frame(width: 38, height: 38)
                    }
                    .padding(.trailing, 5)
                    .padding(.bottom, 3)
                }
                .glassSurface(in: RoundedRectangle(cornerRadius: 22, style: .continuous))

                if isSending {
                    Button {
                        sendTask?.cancel()
                        isSending = false
                    } label: {
                        Image(systemName: "square.fill")
                            .font(.system(size: 13, weight: .bold))
                            .foregroundStyle(CursorTheme.background)
                            .frame(width: 40, height: 40)
                            .background(CursorTheme.accent, in: Circle())
                    }
                } else {
                    Button {
                        sendTask?.cancel()
                        sendTask = Task { await send() }
                    } label: {
                        Image(systemName: "arrow.up")
                            .font(.system(size: 16, weight: .bold))
                            .foregroundStyle(canSend ? CursorTheme.background : CursorTheme.secondaryText)
                            .frame(width: 40, height: 40)
                            .background(canSend ? AnyShapeStyle(CursorTheme.accent) : AnyShapeStyle(CursorTheme.surfaceHigh), in: Circle())
                    }
                    .disabled(!canSend)
                }
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 8)
        }
        .padding(.top, 6)
    }

    private var canSend: Bool {
        app.settings.isOllamaConfigured && !input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    // MARK: Logic

    private func refresh() async {
        guard app.settings.isOllamaConfigured, let url = app.settings.ollamaBaseURL else {
            connectionOK = false
            statusText = "Ollama not configured"
            localModels = []
            return
        }
        do {
            await app.ollama.updateBaseURL(url)
            connectionOK = try await app.ollama.health()
            localModels = try await app.ollama.listLocalModels()
            if let selected = app.settings.selectedChatModel,
               localModels.contains(where: { $0.name == selected }) {
                // keep
            } else {
                app.settings.selectedChatModel = localModels.first?.name
            }
            statusText = connectionOK
                ? "\(app.settings.ollamaHost):\(app.settings.ollamaPort) · \(localModels.count) models"
                : "Ollama unreachable"
        } catch {
            connectionOK = false
            statusText = error.localizedDescription
            localModels = []
        }
    }

    private func send() async {
        guard app.settings.isOllamaConfigured else { return }
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        let model = app.settings.selectedChatModel?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !model.isEmpty else {
            statusText = "Pull a model first"
            return
        }

        input = ""
        app.speechRecognizer.stop()
        messages.append(ChatMessage(role: .user, content: text))
        let assistantID = UUID()
        messages.append(ChatMessage(id: assistantID, role: .assistant, content: "", isStreaming: true))
        isSending = true

        let history = Array(messages.filter { !$0.isStreaming }.suffix(40))
        let payload = history.map { OllamaChatMessage(role: $0.role.rawValue, content: $0.content) }

        var assembled = ""
        do {
            if let url = app.settings.ollamaBaseURL {
                await app.ollama.updateBaseURL(url)
            }
            for try await chunk in await app.ollama.chat(model: model, messages: payload) {
                if Task.isCancelled { break }
                assembled += chunk
                updateAssistant(id: assistantID, content: assembled, streaming: true)
            }
            updateAssistant(id: assistantID, content: assembled.isEmpty && Task.isCancelled ? "(cancelled)" : assembled, streaming: false)
            if !Task.isCancelled, app.settings.speakResponses, !assembled.isEmpty {
                await app.ttsManager.speak(assembled)
            }
        } catch is CancellationError {
            updateAssistant(id: assistantID, content: assembled.isEmpty ? "(cancelled)" : assembled, streaming: false)
        } catch {
            let message = assembled.isEmpty ? "Error: \(error.localizedDescription)" : assembled + "\n\nError: \(error.localizedDescription)"
            updateAssistant(id: assistantID, content: message, streaming: false)
        }
        isSending = false
    }

    private func updateAssistant(id: UUID, content: String, streaming: Bool) {
        guard let idx = messages.firstIndex(where: { $0.id == id }) else { return }
        messages[idx].content = content
        messages[idx].isStreaming = streaming
    }
}

/// Cursor-style rows: user prompts sit in a soft gray bubble on the right,
/// assistant output is plain full-width text.
struct MessageBubble: View {
    let message: ChatMessage

    var body: some View {
        if message.role == .user {
            HStack {
                Spacer(minLength: 48)
                Text(message.content)
                    .font(.body)
                    .textSelection(.enabled)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .fill(CursorTheme.surfaceHigh)
                    )
            }
        } else {
            VStack(alignment: .leading, spacing: 8) {
                if message.content.isEmpty && message.isStreaming {
                    HStack(spacing: 8) {
                        ProgressView().scaleEffect(0.8)
                        Text("Thinking…")
                            .font(.callout)
                            .foregroundStyle(CursorTheme.secondaryText)
                    }
                } else {
                    Text(message.content)
                        .font(.body)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    if message.isStreaming {
                        ProgressView().scaleEffect(0.7)
                    }
                }
            }
        }
    }
}
