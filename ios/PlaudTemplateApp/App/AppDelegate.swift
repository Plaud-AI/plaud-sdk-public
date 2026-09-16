import UIKit
import PlaudDeviceBasicSDK

@main
class AppDelegate: UIResponder, UIApplicationDelegate {

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
    ) -> Bool {
        // Raise the SDK log rotation ceiling so heavy stress runs (e.g. 100x WiFi transfers)
        // are not rotated out before the logs can be exported. Defaults are 10 files x 10MB.
        // These are a debug-oriented ceiling — lower for production builds if disk is a concern.
        PlaudLogConfig.shared.updateFileConfiguration(
            maxFileCount: 50,                 // 1–50
            maxFileAge: 7 * 24 * 60 * 60,     // 7 days (1h–30d)
            maxFileSize: 50 * 1024 * 1024     // 50 MB per file (1–100MB)
        )

        // Build/version stamp so every exported log self-identifies which binary produced it.
        // The marker string also proves the running build includes the latest source — if a log
        // lacks it, the device is running a stale build / cached framework.
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
        AppLog.log("=== App launch — build \(build) — marker: wifi-stability-r2 ===", level: "APP")
        return true
    }

    func application(
        _ application: UIApplication,
        configurationForConnecting connectingSceneSession: UISceneSession,
        options: UIScene.ConnectionOptions
    ) -> UISceneConfiguration {
        return UISceneConfiguration(name: "Default Configuration", sessionRole: connectingSceneSession.role)
    }
}
