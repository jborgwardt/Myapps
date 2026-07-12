import Foundation

/// Tracks an Ollama pull on the main actor so SwiftUI always gets progress updates.
@MainActor
final class ModelPullController: ObservableObject {
    @Published private(set) var isPulling = false
    @Published private(set) var modelName = ""
    @Published private(set) var statusText = ""
    @Published private(set) var fraction: Double?
    @Published private(set) var byteLabel = ""
    @Published private(set) var errorText: String?
    @Published private(set) var didSucceed = false

    private var layerProgress: [String: (completed: Int64, total: Int64)] = [:]
    private var task: Task<Void, Never>?

    func cancel() {
        task?.cancel()
        task = nil
        isPulling = false
        statusText = "Cancelled"
        fraction = nil
        byteLabel = ""
    }

    func pull(name: String, client: OllamaClient, baseURL: URL) {
        task?.cancel()
        let trimmed = OllamaClient.normalizePullName(name)
        guard !trimmed.isEmpty else {
            errorText = "No model name to pull."
            return
        }

        isPulling = true
        didSucceed = false
        errorText = nil
        modelName = trimmed
        statusText = "Starting…"
        fraction = 0
        byteLabel = ""
        layerProgress = [:]

        task = Task { [weak self] in
            guard let self else { return }
            do {
                await client.updateBaseURL(baseURL)
                for try await status in await client.pullModel(name: trimmed) {
                    if Task.isCancelled { throw CancellationError() }
                    self.apply(status: status)
                }
                self.isPulling = false
                self.didSucceed = true
                self.statusText = "Saved \(trimmed)"
                self.fraction = 1
            } catch is CancellationError {
                self.isPulling = false
                self.statusText = "Cancelled"
                self.fraction = nil
            } catch {
                self.isPulling = false
                self.didSucceed = false
                self.errorText = error.localizedDescription
                self.statusText = "Failed"
            }
        }
    }

    private func apply(status: OllamaPullStatus) {
        if let err = status.error, !err.isEmpty {
            errorText = err
            statusText = "Failed"
            return
        }
        if let s = status.status, !s.isEmpty {
            statusText = s
        }
        if let digest = status.digest, let total = status.total, total > 0 {
            let completed = status.completed ?? 0
            layerProgress[digest] = (completed, total)
            let sumCompleted = layerProgress.values.reduce(Int64(0)) { $0 + $1.completed }
            let sumTotal = layerProgress.values.reduce(Int64(0)) { $0 + $1.total }
            if sumTotal > 0 {
                fraction = min(1, Double(sumCompleted) / Double(sumTotal))
                byteLabel = "\(Self.bytes(sumCompleted)) / \(Self.bytes(sumTotal))"
            }
        } else if let total = status.total, total > 0, let completed = status.completed {
            fraction = min(1, Double(completed) / Double(total))
            byteLabel = "\(Self.bytes(completed)) / \(Self.bytes(total))"
        }
        if (status.status ?? "").lowercased() == "success" {
            fraction = 1
            statusText = "success"
        }
    }

    private static func bytes(_ value: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: value, countStyle: .file)
    }
}
