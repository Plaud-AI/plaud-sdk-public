import Foundation
import Combine
import PlaudDeviceBasicSDK

/// Mock implementation for UI development without a real device
final class MockDeviceManager: DeviceManagerProtocol {

    var connectionStatePublisher: AnyPublisher<DeviceConnectionState, Never> {
        connectionStateSubject.eraseToAnyPublisher()
    }
    var connectedDevicePublisher: AnyPublisher<PlaudDevice?, Never> {
        connectedDeviceSubject.eraseToAnyPublisher()
    }
    var scannedDevicesPublisher: AnyPublisher<[ScannedDevice], Never> {
        Just([]).eraseToAnyPublisher()
    }

    private let connectionStateSubject = CurrentValueSubject<DeviceConnectionState, Never>(.connected)
    private let connectedDeviceSubject: CurrentValueSubject<PlaudDevice?, Never>

    init(connected: Bool = true) {
        let mockDevice: PlaudDevice? = connected ? PlaudDevice(
            serialNumber: "MOCK-SN-001",
            name: "Plaud NotePin",
            batteryLevel: 72,
            isCharging: false,
            storageUsed: 512 * 1024 * 1024,   // 512 MB
            storageTotal: 4096 * 1024 * 1024,  // 4 GB
            firmwareVersion: "1.8.0",
            latestFirmwareVersion: "1.9.0",
            latestFirmwareVersionCode: nil,
            supportWiFi: true
        ) : nil
        connectedDeviceSubject = CurrentValueSubject(mockDevice)
        connectionStateSubject.send(connected ? .connected : .disconnected)
    }

    func configure(userId: String) {}
    func startScan() {}
    func stopScan() {}
    func connect(_ device: ScannedDevice, userId: String) {}
    func disconnect() {}
    func unpair() {}
    func switchDevice(sn: String) {}
    func getPairedDevices() -> [PairedDeviceInfo] { [] }
    func refreshDeviceInfo() {}
    func checkFirmwareUpdate(completion: @escaping (PlaudFirmwareCheckResult) -> Void) {}
    func startFirmwareUpdate(progress: @escaping (PlaudFirmwarePhase, Float) -> Void, completion: @escaping (PlaudFirmwareUpdateResult) -> Void) {}
    func setAutoSync(enabled: Bool) {}
}
