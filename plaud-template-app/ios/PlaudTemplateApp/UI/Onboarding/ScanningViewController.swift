import UIKit
import Combine

/// Onboarding Screen 2 — Scanning
///
final class ScanningViewController: UIViewController {

    // MARK: - SDK Integration
    private let deviceManager: DeviceManagerProtocol = DeviceManager.shared
    private var cancellables = Set<AnyCancellable>()
    private var isSheetPresented = false
    private var currentConnectionState: DeviceConnectionState = .disconnected

    /// true = Entered from Home page Add Device (pop back to Home on success)
    /// false = First-time Onboarding (navigate to Success page on success)
    var isAddingDevice = false

    // MARK: - Views

    /// Hint text (width limited to 195pt, naturally wraps to two lines)
    private let subtitleLabel: UILabel = {
        let l = UILabel()
        l.text = "Press record button to turn on Plaud device"
        l.font = PlaudTheme.body()
        l.textColor = PlaudTheme.labelQuaternary
        l.textAlignment = .center
        l.numberOfLines = 2
        l.translatesAutoresizingMaskIntoConstraints = false
        return l
    }()

    /// Scan animation container (194x194)
    private let scanAnimationContainer = UIView()

    /// Blue hazy glow (scan_inner_ellipse 164pt@2x, stretched to 194x194 to fill container)
    private let glowView: UIImageView = {
        let iv = UIImageView(image: UIImage(named: "scan_inner_ellipse"))
        iv.contentMode = .scaleAspectFill
        iv.translatesAutoresizingMaskIntoConstraints = false
        return iv
    }()

    /// BLE icon (44x44, white Bluetooth symbol, centered)
    private let bleIcon: UIImageView = {
        let iv = UIImageView(image: UIImage(named: "icon_ble_scan"))
        iv.contentMode = .scaleAspectFit
        iv.translatesAutoresizingMaskIntoConstraints = false
        return iv
    }()

    /// Static ring (light color, same radius as spinning arc)
    private let staticRing = CAShapeLayer()
    /// Spinning arc (loading animation)
    private let spinningArc = CAShapeLayer()

    /// Status label
    private let statusLabel: UILabel = {
        let l = UILabel()
        l.text = "Searching..."
        l.font = PlaudTheme.body()
        l.textColor = PlaudTheme.labelQuaternary
        l.textAlignment = .center
        l.translatesAutoresizingMaskIntoConstraints = false
        return l
    }()

    /// Bottom warning bar
    private let warningBar: UIView = {
        let v = UIView()
        v.layer.borderWidth = 1
        v.layer.borderColor = UIColor(hex: "#ebebeb").cgColor
        v.layer.cornerRadius = 12
        v.translatesAutoresizingMaskIntoConstraints = false
        return v
    }()

    // MARK: - Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = PlaudTheme.backgroundPrimary
        setupNavBar()
        setupLayout()
        setupBindings()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        setupRingLayers()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        navigationController?.setNavigationBarHidden(false, animated: animated)
        // Add Device 流程中先断开旧设备，禁用自动重连
        if isAddingDevice {
            DeviceManager.shared.suppressAutoReconnect = true
            DeviceManager.shared.disconnect()
        }
        deviceManager.startScan()
        startScanAnimation()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        DeviceManager.shared.suppressAutoReconnect = false
        stopScanAnimation()
    }

    // MARK: - Navigation Bar

    private func setupNavBar() {
        let backBtn = UIButton(type: .system)
        backBtn.setImage(UIImage(systemName: "chevron.left", withConfiguration: UIImage.SymbolConfiguration(pointSize: 17, weight: .medium)), for: .normal)
        backBtn.tintColor = PlaudTheme.labelPrimary
        backBtn.addTarget(self, action: #selector(backTapped), for: .touchUpInside)
        navigationItem.leftBarButtonItem = UIBarButtonItem(customView: backBtn)
        navigationController?.navigationBar.tintColor = PlaudTheme.labelPrimary
    }

    // MARK: - Layout

    private func setupLayout() {
        scanAnimationContainer.translatesAutoresizingMaskIntoConstraints = false
        [glowView, bleIcon].forEach { scanAnimationContainer.addSubview($0) }

        setupWarningBar()

        [subtitleLabel, scanAnimationContainer, statusLabel, warningBar].forEach { view.addSubview($0) }

        NSLayoutConstraint.activate([
            // Subtitle: safe area top + 32, width limited to 195pt for two-line text
            subtitleLabel.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 32),
            subtitleLabel.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            subtitleLabel.widthAnchor.constraint(equalToConstant: 195),

            // Scan animation container: 88pt below subtitle (Figma: 274-186=88)
            scanAnimationContainer.topAnchor.constraint(equalTo: subtitleLabel.bottomAnchor, constant: 88),
            scanAnimationContainer.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            scanAnimationContainer.widthAnchor.constraint(equalToConstant: 194),
            scanAnimationContainer.heightAnchor.constraint(equalToConstant: 194),

            // Hazy glow: fills container 194x194
            glowView.centerXAnchor.constraint(equalTo: scanAnimationContainer.centerXAnchor),
            glowView.centerYAnchor.constraint(equalTo: scanAnimationContainer.centerYAnchor),
            glowView.widthAnchor.constraint(equalToConstant: 194),
            glowView.heightAnchor.constraint(equalToConstant: 194),

            // BLE icon 44x44, centered
            bleIcon.centerXAnchor.constraint(equalTo: scanAnimationContainer.centerXAnchor),
            bleIcon.centerYAnchor.constraint(equalTo: scanAnimationContainer.centerYAnchor),
            bleIcon.widthAnchor.constraint(equalToConstant: 44),
            bleIcon.heightAnchor.constraint(equalToConstant: 44),

            // Status label: 137pt below animation container (Figma: 605-468=137)
            statusLabel.topAnchor.constraint(equalTo: scanAnimationContainer.bottomAnchor, constant: 137),
            statusLabel.centerXAnchor.constraint(equalTo: view.centerXAnchor),

            // Warning bar: pinned to safe area bottom
            warningBar.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor),
            warningBar.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 24),
            warningBar.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -24),
            warningBar.heightAnchor.constraint(equalToConstant: 64),
        ])
    }

    private func setupWarningBar() {
        let iconView = UIImageView(image: UIImage(systemName: "exclamationmark.circle"))
        iconView.tintColor = PlaudTheme.labelQuaternary
        iconView.contentMode = .scaleAspectFit
        iconView.translatesAutoresizingMaskIntoConstraints = false

        let warningLabel = UILabel()
        warningLabel.text = "Device must be unbound from the Plaud App first. Plaud App → Device → Unbind."
        warningLabel.font = PlaudTheme.caption()
        warningLabel.textColor = PlaudTheme.labelQuaternary
        warningLabel.numberOfLines = 2
        warningLabel.translatesAutoresizingMaskIntoConstraints = false

        [iconView, warningLabel].forEach { warningBar.addSubview($0) }

        NSLayoutConstraint.activate([
            iconView.leadingAnchor.constraint(equalTo: warningBar.leadingAnchor, constant: 14),
            iconView.centerYAnchor.constraint(equalTo: warningBar.centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 24),
            iconView.heightAnchor.constraint(equalToConstant: 24),

            warningLabel.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 10),
            warningLabel.trailingAnchor.constraint(equalTo: warningBar.trailingAnchor, constant: -14),
            warningLabel.centerYAnchor.constraint(equalTo: warningBar.centerYAnchor),
        ])
    }

    // MARK: - Ring Layers (static ring + spinning arc)

    private var ringLayersSetup = false

    private func setupRingLayers() {
        guard !ringLayersSetup, scanAnimationContainer.bounds.width > 0 else { return }
        ringLayersSetup = true

        let center = CGPoint(x: 97, y: 97)
        let ringRadius: CGFloat = 82 // ~164pt diameter, matches Figma ring
        let ringPath = UIBezierPath(
            arcCenter: center,
            radius: ringRadius,
            startAngle: 0,
            endAngle: .pi * 2,
            clockwise: true
        )

        // Static ring background
        staticRing.path = ringPath.cgPath
        staticRing.fillColor = UIColor.clear.cgColor
        staticRing.strokeColor = UIColor(hex: "#c1e8fe").withAlphaComponent(0.6).cgColor
        staticRing.lineWidth = 1.5
        staticRing.frame = scanAnimationContainer.bounds
        scanAnimationContainer.layer.addSublayer(staticRing)

        // Spinning arc
        spinningArc.path = ringPath.cgPath
        spinningArc.fillColor = UIColor.clear.cgColor
        spinningArc.strokeColor = UIColor(hex: "#4b90b8").withAlphaComponent(0.7).cgColor
        spinningArc.lineWidth = 2.0
        spinningArc.lineCap = .round
        spinningArc.strokeStart = 0
        spinningArc.strokeEnd = 0.28
        spinningArc.frame = scanAnimationContainer.bounds
        scanAnimationContainer.layer.addSublayer(spinningArc)
    }

    // MARK: - Scan Animation

    private func startScanAnimation() {
        // Glow: slow breathing scale
        let glowPulse = CABasicAnimation(keyPath: "transform.scale")
        glowPulse.fromValue = 0.95
        glowPulse.toValue = 1.05
        glowPulse.duration = 2.0
        glowPulse.autoreverses = true
        glowPulse.repeatCount = .infinity
        glowPulse.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        glowView.layer.add(glowPulse, forKey: "glowPulse")

        // Spinning arc: continuous rotation
        let rotation = CABasicAnimation(keyPath: "transform.rotation.z")
        rotation.fromValue = 0
        rotation.toValue = Double.pi * 2
        rotation.duration = 1.8
        rotation.repeatCount = .infinity
        rotation.timingFunction = CAMediaTimingFunction(name: .linear)
        spinningArc.add(rotation, forKey: "arcSpin")
    }

    private func stopScanAnimation() {
        glowView.layer.removeAllAnimations()
        spinningArc.removeAllAnimations()
    }

    // MARK: - SDK Bindings

    private func setupBindings() {
        // Continuously listen for scan results (don't use .first(), new devices can join anytime)
        deviceManager.scannedDevicesPublisher
            .receive(on: DispatchQueue.main)
            .filter { !$0.isEmpty }
            .sink { [weak self] _ in
                guard let self = self else { return }
                self.statusLabel.text = "Device found!"
                if !self.isSheetPresented {
                    self.showConnectSheet()
                }
            }
            .store(in: &cancellables)

        deviceManager.connectionStatePublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] state in
                guard let self = self else { return }
                self.currentConnectionState = state
                switch state {
                case .connected:
                    self.showSuccess()
                case .disconnected:
                    // Auto rescan after scan timeout
                    self.scheduleRescan()
                default:
                    break
                }
            }
            .store(in: &cancellables)
    }

    /// Auto rescan after timeout (2-second delay to avoid frequent scanning)
    private func scheduleRescan() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
            guard let self = self, self.viewIfLoaded?.window != nil else { return }
            guard case .disconnected = self.currentConnectionState else { return }
            self.statusLabel.text = "Searching..."
            self.deviceManager.startScan()
        }
    }

    // MARK: - Navigation

    @objc private func backTapped() {
        deviceManager.stopScan()
        navigationController?.popViewController(animated: true)
    }

    private func showConnectSheet() {
        isSheetPresented = true
        let sheet = DeviceConnectSheetViewController(deviceManager: deviceManager)
        sheet.onDismiss = { [weak self] in
            self?.isSheetPresented = false
        }
        if #available(iOS 16.0, *) {
            sheet.sheetPresentationController?.detents = [
                .custom { _ in 378 }
            ]
            sheet.sheetPresentationController?.prefersGrabberVisible = false
            sheet.sheetPresentationController?.preferredCornerRadius = 12
        } else if #available(iOS 15.0, *) {
            sheet.sheetPresentationController?.detents = [.medium()]
            sheet.sheetPresentationController?.prefersGrabberVisible = false
            sheet.sheetPresentationController?.preferredCornerRadius = 12
        }
        present(sheet, animated: true)
    }

    private func showSuccess() {
        // Connection successful, cancel all subscriptions (stop rescan)
        cancellables.removeAll()
        deviceManager.stopScan()
        presentedViewController?.dismiss(animated: false)

        if isAddingDevice {
            // Entered from Home Add Device, pop back to Home
            navigationController?.popViewController(animated: true)
        } else {
            // First-time Onboarding, navigate to success page
            let successVC = OnboardingSuccessViewController()
            successVC.modalPresentationStyle = .fullScreen
            present(successVC, animated: true)
        }
    }
}
