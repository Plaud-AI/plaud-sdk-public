import Foundation
import Combine
import PlaudDeviceBasicSDK
import PlaudBleSDK

// MARK: - Protocol

protocol RecordingManagerProtocol: AnyObject {
    /// Recording state stream
    var statePublisher: AnyPublisher<RecordingState, Never> { get }
    /// Real-time volume level (0.0 - 1.0), emitted every 20ms, only during recording
    var waveformLevelPublisher: AnyPublisher<Float, Never> { get }

    func startRecord()
    func stopRecord()
    func pauseRecord()
    func resumeRecord()
}

// MARK: - Real Implementation

final class RecordingManager: RecordingManagerProtocol {

    static let shared = RecordingManager()

    // MARK: Publishers

    var statePublisher: AnyPublisher<RecordingState, Never> {
        stateSubject.eraseToAnyPublisher()
    }
    var waveformLevelPublisher: AnyPublisher<Float, Never> {
        waveformSubject.eraseToAnyPublisher()
    }

    let stateSubject = CurrentValueSubject<RecordingState, Never>(.idle)
    private let waveformSubject = PassthroughSubject<Float, Never>()

    private init() {}

    // MARK: - Recording Control (pass-through to SDK)

    func startRecord() {
        PlaudDeviceAgent.shared.startRecord()
    }

    func stopRecord() {
        PlaudDeviceAgent.shared.stopRecord()
    }

    func pauseRecord() {
        PlaudDeviceAgent.shared.pauseRecord()
    }

    func resumeRecord() {
        PlaudDeviceAgent.shared.resumeRecord()
    }

    // MARK: - Internal Callbacks (forwarded by DeviceManager)

    func handleRecordStart(sessionId: Int, startTime: Int) {
        let startDate: Date
        if sessionId > 0 {
            startDate = Date(timeIntervalSince1970: Double(sessionId))
        } else if startTime > 0 {
            startDate = Date(timeIntervalSince1970: Double(startTime))
        } else {
            startDate = Date()
        }
        DispatchQueue.main.async { [weak self] in
            self?.stateSubject.send(.recording(sessionId: sessionId, startedAt: startDate))
            self?.startWaveformTimer()
        }
    }

    func handleRecordStop(sessionId: Int) {
        DispatchQueue.main.async { [weak self] in
            self?.stopWaveformTimer()
            self?.stateSubject.send(.idle)
        }
        // Auto-sync files 1 second after recording stops
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
            SyncManager.shared.startSync()
        }
    }

    func handleRecordPause(sessionId: Int) {
        DispatchQueue.main.async { [weak self] in
            self?.stateSubject.send(.paused(sessionId: sessionId))
        }
    }

    func handleRecordResume(sessionId: Int, startTime: Int) {
        let date = Date(timeIntervalSince1970: Double(startTime))
        DispatchQueue.main.async { [weak self] in
            self?.stateSubject.send(.recording(sessionId: sessionId, startedAt: date))
        }
    }

    /// Latest volume level (written by BLE callback, read by timer)
    private var latestLevel: Float = 0
    private var waveformTimer: Timer?

    /// Handle decoded PCM data (from blePcmData callback, 640 bytes mono)
    func handlePcmData(pcmData: Data) {
        let volume = JXRecordVolumer.shared.averageVolume(pcmData)
        // averageVolume returns dB value (~0-90), normalize to 0.0-1.0
        latestLevel = Float(min(max(volume, 0), 90)) / 90.0
    }

    /// Start fixed-interval waveform emission (called when recording starts)
    func startWaveformTimer() {
        waveformTimer?.invalidate()
        waveformTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            self.waveformSubject.send(self.latestLevel)
        }
    }

    /// Stop waveform emission (called when recording ends)
    func stopWaveformTimer() {
        waveformTimer?.invalidate()
        waveformTimer = nil
        latestLevel = 0
    }
}
