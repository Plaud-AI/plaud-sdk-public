import Foundation

/// WiFi fast transfer connection phase
enum WiFiConnectPhase {
    case openingHotspot   // BLE command to enable device WiFi hotspot
    case connectingWiFi   // NEHotspotConfiguration connecting (iOS system dialog)
    case handshaking      // WebSocket handshake in progress
}

/// File sync state
enum SyncState {
    case idle
    case syncing(SyncProgress)
    case wifiConnecting(WiFiConnectPhase)
    case wifiTransferring(SyncProgress)
    case completed
    case failed(String)

    var isActive: Bool {
        switch self {
        case .syncing, .wifiConnecting, .wifiTransferring: return true
        default: return false
        }
    }

    var progress: SyncProgress? {
        switch self {
        case .syncing(let p), .wifiTransferring(let p): return p
        default: return nil
        }
    }
}
