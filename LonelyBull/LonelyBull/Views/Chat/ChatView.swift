import SwiftUI

struct ChatView: View {
    @EnvironmentObject private var app: AppModel
    @State private var messages: [ChatMessage] = []
    @State private var input = ""
    @State private var ollamaModels: [OllamaLocalModel] = []
    @State private var isSending = false
    @State private var connectionOK = false
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
            .task {
                await refresh()
                #if DEBUG
                await runSmokeTestIfRequested()
                #endif
            }
            .onDisappear {
                sendTask?.cancel()
                app.localEngine.stopGeneration()
                app.speechRecognizer.stop()
                app.ttsManager.stop()
            }
        }
    }

    private var localModels: [LocalLLMModel] { app.localLLM.installed }

    private var hasAnyModel: Bool {
        !localModels.isEmpty || (app.settings.isOllamaConfigured && !ollamaModels.isEmpty)
    }

    private var selectedIsLocal: Bool { app.settings.selectedModelIsLocal }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 10) {
            HStack(spacing: 7) {
                Circle()
                    .fill(statusColor)
                    .frame(width: 6, height: 6)
                Text(statusLabel)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(CursorTheme.secondaryText)
                    .lineLimit(1)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .glassSurface(in: Capsule())

            Spacer()

            if hasAnyModel {
                Menu {
                    if !localModels.isEmpty {
                        Section("On this iPhone") {
                            ForEach(localModels) { model in
                                modelButton(id: AppSettings.localModelPrefix + model.fileName, title: model.displayName)
                            }
                        }
                    }
                    if app.settings.isOllamaConfigured, !ollamaModels.isEmpty {
                        Section(app.settings.ollamaHost) {
                            ForEach(ollamaModels) { model in
                                modelButton(id: model.name, title: model.name)
                            }
                        }
                    }
                } label: {
                    HStack(spacing: 5) {
                        if selectedIsLocal {
                            Image(systemName: "iphone")
                                .font(.system(size: 10, weight: .semibold))
                        }
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

    private func modelButton(id: String, title: String) -> some View {
        Button {
            app.settings.selectedChatModel = id
        } label: {
            if app.settings.selectedChatModel == id {
                Label(title, systemImage: "checkmark")
            } else {
                Text(title)
            }
        }
    }

    private var statusColor: Color {
        if selectedIsLocal { return .green }
        if app.settings.isOllamaConfigured { return connectionOK ? .green : .orange }
        return localModels.isEmpty ? CursorTheme.secondaryText : .green
    }

    private var statusLabel: String {
        if selectedIsLocal { return "on-device" }
        if app.settings.isOllamaConfigured { return app.settings.ollamaHost }
        return localModels.isEmpty ? "no model yet" : "on-device"
    }

    private var shortModelName: String {
        guard let name = app.settings.selectedChatModel, !name.isEmpty else { return "model" }
        var stripped = name
        if stripped.hasPrefix(AppSettings.localModelPrefix) {
            stripped = String(stripped.dropFirst(AppSettings.localModelPrefix.count))
            stripped = stripped.replacingOccurrences(of: ".gguf", with: "")
        }
        let noOwner = stripped.split(separator: "/").last.map(String.init) ?? stripped
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
            Text(hasAnyModel ? "Ask anything" : "No model yet")
                .font(.title3.weight(.medium))
            Text(emptyStateDetail)
                .font(.footnote)
                .foregroundStyle(CursorTheme.secondaryText)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 44)
            if !hasAnyModel {
                Button("Get a local model") { app.selectedTab = .models }
                    .glassButton()
                    .padding(.top, 4)
            }
            Spacer()
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    private var emptyStateDetail: String {
        if selectedIsLocal {
            return "Running fully on this iPhone — no server, works offline. Replies can be spoken aloud."
        }
        if hasAnyModel {
            return "Replies stream from \(app.settings.ollamaHost) and can be spoken aloud."
        }
        return "Download a model in the Models tab to chat fully on-device — no server needed. Ollama stays optional in Settings."
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
            if app.localEngine.isLoading {
                HStack(spacing: 8) {
                    ProgressView().scaleEffect(0.7)
                    Text("Loading model into memory…")
                        .font(.footnote)
                        .foregroundStyle(CursorTheme.secondaryText)
                    Spacer()
                }
                .padding(.horizontal, 20)
            }
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
                        hasAnyModel ? "Ask anything" : "Get a model in the Models tab",
                        text: $input,
                        axis: .vertical
                    )
                    .textFieldStyle(.plain)
                    .lineLimit(1...5)
                    .padding(.leading, 16)
                    .padding(.vertical, 12)
                    .disabled(!hasAnyModel)

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
                        app.localEngine.stopGeneration()
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
        hasAnyModel && !input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    // MARK: Logic

    private func refresh() async {
        // Pick a sensible default model: prefer what's already selected, else first local, else first Ollama.
        if app.settings.isOllamaConfigured, let url = app.settings.ollamaBaseURL {
            do {
                await app.ollama.updateBaseURL(url)
                connectionOK = try await app.ollama.health()
                ollamaModels = try await app.ollama.listLocalModels()
            } catch {
                connectionOK = false
                ollamaModels = []
            }
        } else {
            connectionOK = false
            ollamaModels = []
        }

        let selected = app.settings.selectedChatModel
        let selectionValid: Bool = {
            guard let selected else { return false }
            if selected.hasPrefix(AppSettings.localModelPrefix) {
                let file = String(selected.dropFirst(AppSettings.localModelPrefix.count))
                return localModels.contains { $0.fileName == file }
            }
            return ollamaModels.contains { $0.name == selected }
        }()

        if !selectionValid {
            if let firstLocal = localModels.first {
                app.settings.selectedChatModel = AppSettings.localModelPrefix + firstLocal.fileName
            } else if let firstRemote = ollamaModels.first {
                app.settings.selectedChatModel = firstRemote.name
            } else {
                app.settings.selectedChatModel = nil
            }
        }
    }

    private func send() async {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        guard let model = app.settings.selectedChatModel, !model.isEmpty else { return }

        input = ""
        app.speechRecognizer.stop()
        let priorMessages = messages
        messages.append(ChatMessage(role: .user, content: text))
        let assistantID = UUID()
        messages.append(ChatMessage(id: assistantID, role: .assistant, content: "", isStreaming: true))
        isSending = true

        var assembled = ""
        do {
            if model.hasPrefix(AppSettings.localModelPrefix) {
                let fileName = String(model.dropFirst(AppSettings.localModelPrefix.count))
                guard let localModel = localModels.first(where: { $0.fileName == fileName }) else {
                    throw LocalChatEngine.LocalLLMError.loadFailed(fileName)
                }
                let stream = try await app.localEngine.stream(prompt: text, history: priorMessages, model: localModel)
                for await chunk in stream {
                    if Task.isCancelled { break }
                    assembled += chunk
                    updateAssistant(id: assistantID, content: assembled, streaming: true)
                }
            } else {
                let history = Array((priorMessages + [ChatMessage(role: .user, content: text)])
                    .filter { !$0.isStreaming }
                    .suffix(40))
                let payload = history.map { OllamaChatMessage(role: $0.role.rawValue, content: $0.content) }
                if let url = app.settings.ollamaBaseURL {
                    await app.ollama.updateBaseURL(url)
                }
                for try await chunk in await app.ollama.chat(model: model, messages: payload) {
                    if Task.isCancelled { break }
                    assembled += chunk
                    updateAssistant(id: assistantID, content: assembled, streaming: true)
                }
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

    #if DEBUG
    /// `-smokeTestPrompt "…"` launch arg: auto-send one message so CI can verify on-device inference.
    private func runSmokeTestIfRequested() async {
        guard let prompt = UserDefaults.standard.string(forKey: "smokeTestPrompt"),
              !prompt.isEmpty, messages.isEmpty else { return }
        input = prompt
        await send()
        NSLog("SMOKETEST_MODEL: %@", app.settings.selectedChatModel ?? "(none)")
        NSLog("SMOKETEST_RESULT: %@", messages.last?.content ?? "(none)")
    }
    #endif
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
