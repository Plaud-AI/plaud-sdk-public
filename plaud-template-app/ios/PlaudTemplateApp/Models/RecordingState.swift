import Foundation

/// Recording state machine
enum RecordingState {
    case idle
    case recording(sessionId: Int, startedAt: Date)
    case paused(sessionId: Int)

    var isActive: Bool {
        if case .idle = self { return false }
        return true
    }

    var currentSessionId: Int? {
        switch self {
        case .recording(let id, _), .paused(let id): return id
        case .idle: return nil
        }
    }
}
