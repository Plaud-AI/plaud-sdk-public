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

    /// Display name for the UI: the SDK's BLE name when present, otherwise a model name derived
    /// from the SN prefix. SDK 1.0.9 can report an empty name, which left the device card showing
    /// only the "Connected" status with a blank title.
    var displayName: String {
        if !name.isEmpty { return name }
        switch String(serialNumber.prefix(3)) {
        case "881": return "Plaud NotePro"
        case "882": return "Plaud NotePin S"
        case "883": return "Plaud NotePin"
        default: return serialNumber.isEmpty ? "Plaud Device" : serialNumber
        }
    }

    /// Device type (determined by SN prefix).
    /// Must match the SDK's internal resolveDeviceType — the cloud device registry is keyed
    /// by (type, sn), and sn-sign registers with the SDK's mapping (882 = NotePin S = "notepins").
    var deviceType: String {
        let prefix = String(serialNumber.prefix(3))
        switch prefix {
        case "881": return "notepro"
        case "882": return "notepins"
        case "883": return "notepin"
        default: return "note"
        }
    }
}

/// Paired device summary info (read from local storage, no BLE connection required)
struct PairedDeviceInfo {
    let serialNumber: String
    let name: String
    let type: String  // notepro/notepin/notepins

    /// Display name for the paired-device list; same empty-name fallback as PlaudDevice.
    var displayName: String {
        if !name.isEmpty { return name }
        switch String(serialNumber.prefix(3)) {
        case "881": return "Plaud NotePro"
        case "882": return "Plaud NotePin S"
        case "883": return "Plaud NotePin"
        default: return serialNumber.isEmpty ? "Plaud Device" : serialNumber
        }
    }

    /// Device type (determined by SN prefix).
    /// Must match the SDK's internal resolveDeviceType (see PlaudDevice.deviceType above).
    static func deviceType(for sn: String) -> String {
        let prefix = String(sn.prefix(3))
        switch prefix {
        case "881": return "notepro"
        case "882": return "notepins"
        case "883": return "notepin"
        default: return "note"
        }
    }
}
