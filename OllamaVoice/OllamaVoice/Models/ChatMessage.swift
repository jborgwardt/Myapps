import Foundation

struct ChatMessage: Identifiable, Equatable, Codable {
    let id: UUID
    var role: Role
    var content: String
    var createdAt: Date
    var isStreaming: Bool

    enum Role: String, Codable {
        case system, user, assistant
    }

    init(
        id: UUID = UUID(),
        role: Role,
        content: String,
        createdAt: Date = .now,
        isStreaming: Bool = false
    ) {
        self.id = id
        self.role = role
        self.content = content
        self.createdAt = createdAt
        self.isStreaming = isStreaming
    }
}
