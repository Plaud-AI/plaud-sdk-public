import Foundation

/// BLE scanned device, displayed for user selection before connecting
struct ScannedDevice: Equatable {
    let name: String
    let serialNumber: String  // Maps to BleDevice.serialNumber
    let rssi: Float           // Signal strength
}
