import Foundation

/// Device connection state machine
enum DeviceConnectionState {
    case disconnected
    case scanning
    case connecting(ScannedDevice)
    case connected
    case failed(String)
}
