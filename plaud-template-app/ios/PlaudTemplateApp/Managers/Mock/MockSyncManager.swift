import Foundation
import Combine

/// Mock Sync Manager for Files / Settings UI development
final class MockSyncManager: SyncManagerProtocol {

    var statePublisher: AnyPublisher<SyncState, Never> {
        stateSubject.eraseToAnyPublisher()
    }
    var filesPublisher: AnyPublisher<[RecordingFile], Never> {
        filesSubject.eraseToAnyPublisher()
    }

    private let stateSubject = CurrentValueSubject<SyncState, Never>(.idle)
    private let filesSubject: CurrentValueSubject<[RecordingFile], Never>

    init() {
        filesSubject = CurrentValueSubject(MockSyncManager.makeMockFiles())
    }

    func fetchFileList() {}

    func startSync() {
        // Simulate sync process
        stateSubject.send(.syncing(SyncProgress(totalFiles: 3, syncedFiles: 0, currentFileName: "Untitled Recording")))
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            self?.stateSubject.send(.completed)
        }
    }

    func startWiFiTransfer() {}
    func stopWiFiTransfer() {}
    func stopSync() { stateSubject.send(.idle) }

    func deleteFile(_ file: RecordingFile) {
        var files = filesSubject.value
        files.removeAll { $0.id == file.id }
        filesSubject.send(files)
    }

    func renameFile(_ file: RecordingFile, name: String) {
        var files = filesSubject.value
        if let idx = files.firstIndex(where: { $0.id == file.id }) {
            files[idx].name = name
            filesSubject.send(files)
        }
    }

    func exportAudio(_ file: RecordingFile, completion: @escaping (Result<URL, Error>) -> Void) {
        // Mock: simulate successful export
        let mockURL = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("\(file.sessionId).mp3")
        completion(.success(mockURL))
    }

    // MARK: - Mock Data

    private static func makeMockFiles() -> [RecordingFile] {
        let now = Date()
        return [
            RecordingFile(
                id: "mock-1",
                sessionId: Int(now.timeIntervalSince1970) - 86400,
                deviceSN: "MOCK-SN-001",
                name: "Team Standup",
                duration: 1823,
                createdAt: now.addingTimeInterval(-86400),
                syncedAt: now.addingTimeInterval(-86300),
                localPath: "/mock/path/1.mp3",
                summaryText: "Today's standup discussed Q2 goals and sprint planning.",
                transcriptJSON: nil
            ),
            RecordingFile(
                id: "mock-2",
                sessionId: Int(now.timeIntervalSince1970) - 172800,
                deviceSN: "MOCK-SN-001",
                name: "Product Review",
                duration: 3612,
                createdAt: now.addingTimeInterval(-172800),
                syncedAt: now.addingTimeInterval(-172700),
                localPath: "/mock/path/2.mp3",
                summaryText: nil,
                transcriptJSON: nil
            ),
            RecordingFile(
                id: "mock-3",
                sessionId: Int(now.timeIntervalSince1970) - 3600,
                deviceSN: "MOCK-SN-001",
                name: RecordingFile.defaultName,
                duration: 0,
                createdAt: now.addingTimeInterval(-3600),
                syncedAt: nil,
                localPath: nil,
                summaryText: nil,
                transcriptJSON: nil
            )
        ]
    }
}
