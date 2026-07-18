import UIKit

class SceneDelegate: UIResponder, UIWindowSceneDelegate {

    var window: UIWindow?

    func scene(
        _ scene: UIScene,
        willConnectTo session: UISceneSession,
        options connectionOptions: UIScene.ConnectionOptions
    ) {
        guard let windowScene = scene as? UIWindowScene else { return }
        window = UIWindow(windowScene: windowScene)
        if !RecordingStore.shared.pairedDeviceSNs.isEmpty,
           RecordingStore.shared.userId != nil {
            let userId = RecordingStore.shared.userId!
            DeviceManager.shared.configure(userId: userId)
            window?.rootViewController = MainTabBarController()
        } else {
            window?.rootViewController = UINavigationController(rootViewController: WelcomeViewController())
        }
        window?.makeKeyAndVisible()
    }

    func sceneDidBecomeActive(_ scene: UIScene) {
        NotificationCenter.default.post(name: .appDidBecomeActive, object: nil)

        guard RecordingStore.shared.activeDeviceSN != nil,
              RecordingStore.shared.userId != nil else { return }

        // Only scan for reconnection if not connected and not in OTA (wait for BLE power on)
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            if case .connected = DeviceManager.shared.currentConnectionState { return }
            if DeviceManager.shared.isOTAInProgress { return }
            DeviceManager.shared.startScan()
        }
    }
}

extension Notification.Name {
    static let appDidBecomeActive = Notification.Name("com.plaud.template.appDidBecomeActive")
}
