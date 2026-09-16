import Foundation
import Combine

/// Mock Recording Manager for UI development
final class MockRecordingManager: RecordingManagerProtocol {

    var statePublisher: AnyPublisher<RecordingState, Never> {
        stateSubject.eraseToAnyPublisher()
    }
    var waveformLevelPublisher: AnyPublisher<Float, Never> {
        waveformSubject.eraseToAnyPublisher()
    }

    private let stateSubject = CurrentValueSubject<RecordingState, Never>(.idle)
    private let waveformSubject = PassthroughSubject<Float, Never>()
    private var waveformTimer: AnyCancellable?

    func startRecord() {
        stateSubject.send(.recording(sessionId: 9001, startedAt: Date()))
        // Simulate real-time waveform
        waveformTimer = Timer.publish(every: 0.05, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in
                self?.waveformSubject.send(Float.random(in: 0.1...0.9))
            }
    }

    func stopRecord() {
        waveformTimer?.cancel()
        stateSubject.send(.idle)
    }

    func pauseRecord() {
        stateSubject.send(.paused(sessionId: 9001))
    }

    func resumeRecord() {
        stateSubject.send(.recording(sessionId: 9001, startedAt: Date()))
    }
}
