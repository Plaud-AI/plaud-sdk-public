import Foundation
import PlaudDeviceBasicSDK

/// App-level diagnostic logging.
///
/// Mirrors every message to both the Xcode console (`print`) and the SDK's unified log file
/// (`Documents/PlaudLogs/plaud.log`, with rotation) via `PlaudLogRedirect.addLog`. This is what
/// makes app-side logs — e.g. `[SyncManager]` / `[DeviceManager]` / `[WiFiExport]` — show up in
/// the exported `.plaud` bundle, instead of living only in the Xcode console.
enum AppLog {
    static func log(_ message: String, level: String = "APP") {
        print(message)
        PlaudLogRedirect.addLog(message, level: level)
    }
}
