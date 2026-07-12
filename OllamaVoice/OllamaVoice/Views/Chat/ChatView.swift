import SwiftUI

struct ChatView: View {
    @EnvironmentObject private var app: AppModel
    @State private var messages: [ChatMessage] = [
        ChatMessage(role: .assistant, content: "Connected to Ollama. Pick a model and ask anything — or hold the mic to talk.")
    ]
    @State private var input = ""
    @State private var localModels: [OllamaLocalModel] = []
    @State private var isSending = false
    @State private var connectionOK = false
    @State private var statusText = "Checking Ollama…"

    var body: some View {
        NavigationStack {
            ZStack {
                LinearGradient(
                    colors: [
                        Color(red: 0.06, green: 0.09, blue: 0.12),
                        Color(red: 0.08, green: 0.14, blue: 0.16)
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                .ignoresSafeArea()

                VStack(spacing: 0) {
                    header
                    Divider().overlay(Color.white.opacity(0.08))
                    messageList
                    composer
                }
            }
            .navigationTitle("Ollama Voice")
            .navigationBarTitleDisplayMode(.inline)
            .task { await refresh() }
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Circle()
                .fill(connectionOK ? Color.green : Color.orange)
                .frame(width: 8, height: 8)
            Text(statusText)
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            Picker("Model", selection: Binding(
                get: { app.settings.selectedChatModel ?? localModels.first?.name ?? "" },
                set: { app.settings.selectedChatModel = $0 }
            )) {
                ForEach(localModels) { model in
                    Text(model.name).tag(model.name)
                }
            }
            .pickerStyle(.menu)
        }
        .padding(.horizontal)
        .padding(.vertical, 10)
    }

    private var messageList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    ForEach(messages) { message in
                        MessageBubble(message: message)
                            .id(message.id)
                    }
                }
                .padding()
            }
            .onChange(of: messages) { _, _ in
                if let last = messages.last {
                    withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
                }
            }
        }
    }

    private var composer: some View {
        VStack(spacing: 8) {
            if app.speechRecognizer.isRecording {
                Text(app.speechRecognizer.transcript.isEmpty ? "Listening…" : app.speechRecognizer.transcript)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal)
            }

            HStack(alignment: .bottom, spacing: 10) {
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
                        .font(.title3)
                        .foregroundStyle(app.speechRecognizer.isRecording ? Color.red : Color.primary)
                        .frame(width: 40, height: 40)
                }

                TextField("Message", text: $input, axis: .vertical)
                    .textFieldStyle(.plain)
                    .lineLimit(1...5)
                    .padding(10)
                    .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 12))

                Button {
                    Task { await send() }
                } label: {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.system(size: 32))
                        .symbolRenderingMode(.hierarchical)
                }
                .disabled(input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isSending)
            }
            .padding(.horizontal)
            .padding(.bottom, 10)
        }
        .padding(.top, 8)
        .background(.ultraThinMaterial)
    }

    private func refresh() async {
        do {
            connectionOK = try await app.ollama.health()
            localModels = try await app.ollama.listLocalModels()
            if app.settings.selectedChatModel == nil {
                app.settings.selectedChatModel = localModels.first?.name
            }
            statusText = connectionOK
                ? "\(app.settings.ollamaHost):\(app.settings.ollamaPort) · \(localModels.count) models"
                : "Ollama unreachable"
        } catch {
            connectionOK = false
            statusText = error.localizedDescription
        }
    }

    private func send() async {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        guard let model = app.settings.selectedChatModel, !model.isEmpty else {
            statusText = "Pull a model first"
            return
        }

        input = ""
        messages.append(ChatMessage(role: .user, content: text))
        let assistantID = UUID()
        messages.append(ChatMessage(id: assistantID, role: .assistant, content: "", isStreaming: true))
        isSending = true

        let payload = messages
            .filter { !$0.isStreaming }
            .map { OllamaChatMessage(role: $0.role.rawValue, content: $0.content) }

        var assembled = ""
        do {
            for try await chunk in await app.ollama.chat(model: model, messages: payload) {
                assembled += chunk
                if let idx = messages.firstIndex(where: { $0.id == assistantID }) {
                    messages[idx].content = assembled
                }
            }
            if let idx = messages.firstIndex(where: { $0.id == assistantID }) {
                messages[idx].isStreaming = false
            }
            if app.settings.speakResponses {
                await app.ttsManager.speak(assembled)
            }
        } catch {
            if let idx = messages.firstIndex(where: { $0.id == assistantID }) {
                messages[idx].content = "Error: \(error.localizedDescription)"
                messages[idx].isStreaming = false
            }
        }
        isSending = false
    }
}

struct MessageBubble: View {
    let message: ChatMessage

    var body: some View {
        HStack {
            if message.role == .user { Spacer(minLength: 40) }
            VStack(alignment: .leading, spacing: 4) {
                Text(message.content.isEmpty && message.isStreaming ? "…" : message.content)
                    .font(.body)
                    .textSelection(.enabled)
                if message.isStreaming {
                    ProgressView()
                        .scaleEffect(0.7)
                }
            }
            .padding(12)
            .background(
                RoundedRectangle(cornerRadius: 16)
                    .fill(message.role == .user
                          ? Color(red: 0.18, green: 0.42, blue: 0.40)
                          : Color.white.opacity(0.07))
            )
            if message.role != .user { Spacer(minLength: 40) }
        }
    }
}
