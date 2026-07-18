import UIKit

/// Onboarding Screen 1 — Welcome
///
final class WelcomeViewController: UIViewController {

    // MARK: - Views

    /// App logo placeholder icon (B2B customers replace with their own logo)
    private let logoContainer: UIView = {
        let v = UIView()
        v.layer.borderWidth = 0.8
        v.layer.borderColor = UIColor(hex: "#adadad").cgColor
        v.layer.cornerRadius = 5.714
        v.clipsToBounds = true
        v.translatesAutoresizingMaskIntoConstraints = false
        return v
    }()

    private let logoIcon: UIImageView = {
        let iv = UIImageView(image: UIImage(systemName: "square.grid.2x2"))
        iv.tintColor = .label
        iv.contentMode = .scaleAspectFit
        iv.translatesAutoresizingMaskIntoConstraints = false
        return iv
    }()

    /// App name label (B2B customers replace with their own brand name)
    private let appNameLabel: UILabel = {
        let l = UILabel()
        l.text = "App name"
        l.font = PlaudTheme.largeTitle()
        l.textColor = PlaudTheme.labelPrimary
        l.textAlignment = .center
        l.translatesAutoresizingMaskIntoConstraints = false
        return l
    }()

    /// Get Started button
    private lazy var getStartedButton: UIButton = {
        let btn = PlaudTheme.makeSecondaryButton(title: "Get Started")
        btn.addTarget(self, action: #selector(getStartedTapped), for: .touchUpInside)
        return btn
    }()

    /// Background gradient image (804x1094 @2x PNG)
    private let backgroundImageView: UIImageView = {
        let iv = UIImageView(image: UIImage(named: "welcome_bg"))
        iv.contentMode = .scaleToFill
        iv.translatesAutoresizingMaskIntoConstraints = false
        return iv
    }()

    // MARK: - Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .white
        navigationController?.setNavigationBarHidden(true, animated: false)
        setupLayout()
    }

    // MARK: - Layout

    private func setupLayout() {
        [backgroundImageView, logoContainer, appNameLabel, getStartedButton].forEach { view.addSubview($0) }
        logoContainer.addSubview(logoIcon)

        NSLayoutConstraint.activate([
            // Background fills entire screen
            backgroundImageView.topAnchor.constraint(equalTo: view.topAnchor),
            backgroundImageView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            backgroundImageView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            backgroundImageView.trailingAnchor.constraint(equalTo: view.trailingAnchor),

            // Logo container 64x64, horizontally centered
            // y = 197pt from frame top, frame has 62pt statusBar + 44pt navBar, we hide navBar, so safeArea top + 91
            logoContainer.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 91),
            logoContainer.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            logoContainer.widthAnchor.constraint(equalToConstant: 64),
            logoContainer.heightAnchor.constraint(equalToConstant: 64),

            // Logo icon, 14pt padding
            logoIcon.centerXAnchor.constraint(equalTo: logoContainer.centerXAnchor),
            logoIcon.centerYAnchor.constraint(equalTo: logoContainer.centerYAnchor),
            logoIcon.widthAnchor.constraint(equalToConstant: 36),
            logoIcon.heightAnchor.constraint(equalToConstant: 36),

            // App name, 34pt below logo (Figma: 295-261=34)
            appNameLabel.topAnchor.constraint(equalTo: logoContainer.bottomAnchor, constant: 34),
            appNameLabel.centerXAnchor.constraint(equalTo: view.centerXAnchor),

            // Get Started button, 24pt from bottom safeArea (Figma: 840-816=24)
            getStartedButton.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -24),
            getStartedButton.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 24),
            getStartedButton.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -24),
            getStartedButton.heightAnchor.constraint(equalToConstant: 48),
        ])
    }

    // MARK: - Actions

    @objc private func getStartedTapped() {
        // Extract sub from partnerToken JWT as userId
        let userId = Self.extractUserId()
        RecordingStore.shared.userId = userId
        DeviceManager.shared.configure(userId: userId)
        pushScanning()
    }

    /// Parse the sub field from partnerToken JWT payload as userId
    private static func extractUserId() -> String {
        let token = DeviceManager.shared.partnerToken
        let parts = token.split(separator: ".")
        guard parts.count >= 2,
              let data = Data(base64Encoded: String(parts[1]).base64Padded()),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let sub = json["sub"] as? String
        else {
            return UUID().uuidString
        }
        return sub
    }

    private func pushScanning() {
        navigationController?.pushViewController(ScanningViewController(), animated: true)
    }
}
