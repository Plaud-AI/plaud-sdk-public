import Foundation

/// Connected device state
struct PlaudDevice {
    let serialNumber: String           // Device SN (unique identifier)
    var name: String                   // Device name (mutable)
    var batteryLevel: Int              // Battery level 0-100
    var isCharging: Bool               // Whether charging
    var storageUsed: Int64             // Used storage (bytes)
    var storageTotal: Int64            // Total storage (bytes)
    var firmwareVersion: String        // Firmware version for display (e.g. "V1.4.7")
    var latestFirmwareVersion: String? // Latest cloud version (nil = not checked or up to date)
    var latestFirmwareVersionCode: Int? // Cloud version code (integer for OTA)
    var supportWiFi: Bool              // Whether device supports WiFi fast transfer

    /// Storage usage ratio 0.0 - 1.0
    var storageUsageRatio: Float {
        guard storageTotal > 0 else { return 0 }
        return Float(storageUsed) / Float(storageTotal)
    }

    /// Device type (determined by SN prefix)
    var deviceType: String {
        let prefix = String(serialNumber.prefix(3))
        switch prefix {
        case "881": return "notepro"
        case "882": return "notepin"
        case "883": return "notepins"
        default: return "note"
        }
    }
}

/// Paired device summary info (read from local storage, no BLE connection required)
struct PairedDeviceInfo {
    let serialNumber: String
    let name: String
    let type: String  // notepro/notepin/notepins

    /// Device type (determined by SN prefix)
    static func deviceType(for sn: String) -> String {
        let prefix = String(sn.prefix(3))
        switch prefix {
        case "881": return "notepro"
        case "882": return "notepin"
        case "883": return "notepins"
        default: return "note"
        }
    }
}
