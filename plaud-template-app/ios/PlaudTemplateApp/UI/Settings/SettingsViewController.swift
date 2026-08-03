import UIKit
import Combine
import PlaudDeviceBasicSDK

/// Settings page: Automatic Sync + Device Firmware + Sign out
final class SettingsViewController: UIViewController {

    // MARK: - SDK Integration
    private let deviceManager: DeviceManagerProtocol = DeviceManager.shared
    private var cancellables = Set<AnyCancellable>()
    private var connectedDevice: PlaudDevice?
    private var fwVersionBottomConstraint: NSLayoutConstraint?

    // MARK: - Views
    private let scrollView = UIScrollView()
    private let contentView = UIView()

    private let titleLabel: UILabel = {
        let l = UILabel()
        l.text = "Settings"
        l.font = .systemFont(ofSize: 44, weight: .light)
        l.textColor = .black
        l.translatesAutoresizingMaskIntoConstraints = false
        return l
    }()

    // Card 1: Automatic Sync
    private let syncCard = UIView()
    private let syncToggle = PlaudToggle()

    // Card 2: Device Firmware
    private let firmwareCard = UIView()
    private let fwVersionLabel = UILabel()
    private let fwProgressView: UIProgressView = {
        let pv = UIProgressView(progressViewStyle: .default)
        pv.progressTintColor = .black
        pv.trackTintColor = UIColor(hex: "#EBEBEB")
        pv.translatesAutoresizingMaskIntoConstraints = false
        pv.isHidden = true
        return pv
    }()
    private let fwStatusLabel: UILabel = {
        let l = UILabel()
        l.font = .systemFont(ofSize: 12)
        l.textColor = UIColor(hex: "#7A7A7A")
        l.translatesAutoresizingMaskIntoConstraints = false
        l.isHidden = true
        return l
    }()
    private lazy var fwUpdateButton: UIButton = {
        let btn = UIButton(type: .custom)
        btn.setTitle("Update", for: .normal)
        btn.setTitleColor(.white, for: .normal)
        btn.titleLabel?.font = .systemFont(ofSize: 14, weight: .semibold)
        btn.backgroundColor = .black
        btn.layer.cornerRadius = 12
        btn.contentEdgeInsets = UIEdgeInsets(top: 0, left: 16, bottom: 0, right: 16)
        btn.translatesAutoresizingMaskIntoConstraints = false
        btn.addTarget(self, action: #selector(firmwareUpdateTapped), for: .touchUpInside)
        return btn
    }()

    // Card 3: SDK Logs
    private let logsCard = UIView()
    private lazy var logsExportButton: UIButton = {
        let btn = UIButton(type: .custom)
        btn.setTitle("Export", for: .normal)
        btn.setTitleColor(.white, for: .normal)
        btn.titleLabel?.font = .systemFont(ofSize: 14, weight: .semibold)
        btn.backgroundColor = .black
        btn.layer.cornerRadius = 12
        btn.contentEdgeInsets = UIEdgeInsets(top: 0, left: 16, bottom: 0, right: 16)
        btn.translatesAutoresizingMaskIntoConstraints = false
        btn.addTarget(self, action: #selector(exportLogsTapped), for: .touchUpInside)
        return btn
    }()

    // Card 4: User Access Token (account-switch entry for SDK customers)
    private let tokenCard = UIView()
    private let tokenInfoLabel = UILabel()
    private lazy var tokenReplaceButton: UIButton = {
        let btn = UIButton(type: .custom)
        btn.setTitle("Replace", for: .normal)
        btn.setTitleColor(.white, for: .normal)
        btn.titleLabel?.font = .systemFont(ofSize: 14, weight: .semibold)
        btn.backgroundColor = .black
        btn.layer.cornerRadius = 12
        btn.contentEdgeInsets = UIEdgeInsets(top: 0, left: 16, bottom: 0, right: 16)
        btn.translatesAutoresizingMaskIntoConstraints = false
        btn.addTarget(self, action: #selector(replaceTokenTapped), for: .touchUpInside)
        return btn
    }()

    // Card 4b: API Key (transcription X-Client-Api-Key, applies immediately)
    private let apiKeyCard = UIView()
    private let apiKeyInfoLabel = UILabel()
    private lazy var apiKeyReplaceButton: UIButton = {
        let btn = UIButton(type: .custom)
        btn.setTitle("Replace", for: .normal)
        btn.setTitleColor(.white, for: .normal)
        btn.titleLabel?.font = .systemFont(ofSize: 14, weight: .semibold)
        btn.backgroundColor = .black
        btn.layer.cornerRadius = 12
        btn.contentEdgeInsets = UIEdgeInsets(top: 0, left: 16, bottom: 0, right: 16)
        btn.translatesAutoresizingMaskIntoConstraints = false
        btn.addTarget(self, action: #selector(replaceApiKeyTapped), for: .touchUpInside)
        return btn
    }()

    // Card 5: Server Environment (production / test domain switch, restart to apply)
    private let envCard = UIView()
    private let envInfoLabel = UILabel()
    private lazy var envSwitchButton: UIButton = {
        let btn = UIButton(type: .custom)
        btn.setTitle("Switch", for: .normal)
        btn.setTitleColor(.white, for: .normal)
        btn.titleLabel?.font = .systemFont(ofSize: 14, weight: .semibold)
        btn.backgroundColor = .black
        btn.layer.cornerRadius = 12
        btn.contentEdgeInsets = UIEdgeInsets(top: 0, left: 16, bottom: 0, right: 16)
        btn.translatesAutoresizingMaskIntoConstraints = false
        btn.addTarget(self, action: #selector(switchEnvTapped), for: .touchUpInside)
        return btn
    }()

    // Card 6: App version (read-only, helps QA report the exact build)
    private let versionCard = UIView()
    private let versionValueLabel = UILabel()

    // Sign out button
    private lazy var signOutButton: UIButton = {
        let btn = UIButton(type: .custom)
        btn.setTitle("Sign out", for: .normal)
        btn.setTitleColor(.black, for: .normal)
        btn.titleLabel?.font = .systemFont(ofSize: 16)
        btn.backgroundColor = .white
        btn.layer.cornerRadius = 12
        btn.translatesAutoresizingMaskIntoConstraints = false
        btn.addTarget(self, action: #selector(signOutTapped), for: .touchUpInside)
        return btn
    }()

    // MARK: - Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = PlaudTheme.backgroundPrimary
        navigationController?.setNavigationBarHidden(true, animated: false)
        setupLayout()
        setupBindings()
    }

    // MARK: - Layout

    private func setupLayout() {
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.alwaysBounceVertical = true
        scrollView.showsVerticalScrollIndicator = false
        view.addSubview(scrollView)

        contentView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.addSubview(contentView)

        setupFirmwareCard()
        setupLogsCard()
        setupTokenCard()
        setupApiKeyCard()
        setupEnvCard()
        setupVersionCard()

        [titleLabel, firmwareCard, logsCard, tokenCard, apiKeyCard, envCard, versionCard, signOutButton].forEach { contentView.addSubview($0) }

        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),

            contentView.topAnchor.constraint(equalTo: scrollView.topAnchor),
            contentView.bottomAnchor.constraint(equalTo: scrollView.bottomAnchor),
            contentView.leadingAnchor.constraint(equalTo: scrollView.leadingAnchor),
            contentView.trailingAnchor.constraint(equalTo: scrollView.trailingAnchor),
            contentView.widthAnchor.constraint(equalTo: scrollView.widthAnchor),

            titleLabel.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 16),
            titleLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 24),

            firmwareCard.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 40),
            firmwareCard.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 24),
            firmwareCard.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -24),

            logsCard.topAnchor.constraint(equalTo: firmwareCard.bottomAnchor, constant: 16),
            logsCard.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 24),
            logsCard.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -24),

            tokenCard.topAnchor.constraint(equalTo: logsCard.bottomAnchor, constant: 16),
            tokenCard.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 24),
            tokenCard.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -24),

            apiKeyCard.topAnchor.constraint(equalTo: tokenCard.bottomAnchor, constant: 16),
            apiKeyCard.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 24),
            apiKeyCard.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -24),

            envCard.topAnchor.constraint(equalTo: apiKeyCard.bottomAnchor, constant: 16),
            envCard.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 24),
            envCard.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -24),

            versionCard.topAnchor.constraint(equalTo: envCard.bottomAnchor, constant: 16),
            versionCard.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 24),
            versionCard.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -24),

            signOutButton.topAnchor.constraint(equalTo: versionCard.bottomAnchor, constant: 24),
            signOutButton.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 24),
            signOutButton.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -24),
            signOutButton.heightAnchor.constraint(equalToConstant: 48),
            signOutButton.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -120),
        ])
    }

    private func setupSyncCard() {
        syncCard.backgroundColor = .white
        syncCard.layer.cornerRadius = 12
        syncCard.translatesAutoresizingMaskIntoConstraints = false

        let icon = UIImageView(image: UIImage(named: "icon_cloud_sync"))
        icon.contentMode = .scaleAspectFit
        icon.translatesAutoresizingMaskIntoConstraints = false

        let titleLbl = UILabel()
        titleLbl.text = "Automatic Sync"
        titleLbl.font = .systemFont(ofSize: 14)
        titleLbl.textColor = .black
        titleLbl.translatesAutoresizingMaskIntoConstraints = false

        let subtitleLbl = UILabel()
        subtitleLbl.text = "Auto transfer recordings via BLE"
        subtitleLbl.font = .systemFont(ofSize: 13)
        subtitleLbl.textColor = UIColor(hex: "#7A7A7A")
        subtitleLbl.translatesAutoresizingMaskIntoConstraints = false

        syncToggle.isOn = RecordingStore.shared.isAutoSyncEnabled
        syncToggle.translatesAutoresizingMaskIntoConstraints = false
        syncToggle.onToggle = { [weak self] isOn in
            self?.deviceManager.setAutoSync(enabled: isOn)
        }

        [icon, titleLbl, subtitleLbl, syncToggle].forEach { syncCard.addSubview($0) }

        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: syncCard.leadingAnchor, constant: 16),
            icon.centerYAnchor.constraint(equalTo: syncCard.centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 32),
            icon.heightAnchor.constraint(equalToConstant: 32),

            titleLbl.topAnchor.constraint(equalTo: syncCard.topAnchor, constant: 16),
            titleLbl.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 12),

            subtitleLbl.topAnchor.constraint(equalTo: titleLbl.bottomAnchor, constant: 2),
            subtitleLbl.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 12),
            subtitleLbl.bottomAnchor.constraint(equalTo: syncCard.bottomAnchor, constant: -16),

            syncToggle.centerYAnchor.constraint(equalTo: syncCard.centerYAnchor),
            syncToggle.trailingAnchor.constraint(equalTo: syncCard.trailingAnchor, constant: -16),
            syncToggle.widthAnchor.constraint(equalToConstant: 48),
            syncToggle.heightAnchor.constraint(equalToConstant: 26),
        ])
    }

    private func setupFirmwareCard() {
        firmwareCard.backgroundColor = .white
        firmwareCard.layer.cornerRadius = 12
        firmwareCard.translatesAutoresizingMaskIntoConstraints = false

        let icon = UIImageView(image: UIImage(named: "icon_firmware"))
        icon.contentMode = .scaleAspectFit
        icon.translatesAutoresizingMaskIntoConstraints = false

        let titleLbl = UILabel()
        titleLbl.text = "Device Firmware"
        titleLbl.font = .systemFont(ofSize: 14)
        titleLbl.textColor = .black
        titleLbl.translatesAutoresizingMaskIntoConstraints = false

        fwVersionLabel.text = "Version --"
        fwVersionLabel.font = .systemFont(ofSize: 13)
        fwVersionLabel.textColor = UIColor(hex: "#7A7A7A")
        fwVersionLabel.translatesAutoresizingMaskIntoConstraints = false

        [icon, titleLbl, fwVersionLabel, fwUpdateButton, fwProgressView, fwStatusLabel].forEach { firmwareCard.addSubview($0) }

        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: firmwareCard.leadingAnchor, constant: 16),
            icon.topAnchor.constraint(equalTo: firmwareCard.topAnchor, constant: 20),
            icon.widthAnchor.constraint(equalToConstant: 32),
            icon.heightAnchor.constraint(equalToConstant: 32),

            titleLbl.topAnchor.constraint(equalTo: firmwareCard.topAnchor, constant: 16),
            titleLbl.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 12),

            fwVersionLabel.topAnchor.constraint(equalTo: titleLbl.bottomAnchor, constant: 2),
            fwVersionLabel.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 12),

            fwUpdateButton.centerYAnchor.constraint(equalTo: titleLbl.centerYAnchor, constant: 6),
            fwUpdateButton.trailingAnchor.constraint(equalTo: firmwareCard.trailingAnchor, constant: -16),
            fwUpdateButton.heightAnchor.constraint(equalToConstant: 32),
            fwUpdateButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 64),

            fwProgressView.topAnchor.constraint(equalTo: fwVersionLabel.bottomAnchor, constant: 10),
            fwProgressView.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 12),
            fwProgressView.trailingAnchor.constraint(equalTo: firmwareCard.trailingAnchor, constant: -16),
            fwProgressView.heightAnchor.constraint(equalToConstant: 4),

            fwStatusLabel.topAnchor.constraint(equalTo: fwProgressView.bottomAnchor, constant: 4),
            fwStatusLabel.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 12),
            fwStatusLabel.bottomAnchor.constraint(equalTo: firmwareCard.bottomAnchor, constant: -12),
        ])

        // Bottom constraint when no progress bar is shown
        fwVersionBottomConstraint = fwVersionLabel.bottomAnchor.constraint(equalTo: firmwareCard.bottomAnchor, constant: -16)
        fwVersionBottomConstraint?.isActive = true
    }

    private func setupLogsCard() {
        logsCard.backgroundColor = .white
        logsCard.layer.cornerRadius = 12
        logsCard.translatesAutoresizingMaskIntoConstraints = false

        let titleLbl = UILabel()
        titleLbl.text = "SDK Logs"
        titleLbl.font = .systemFont(ofSize: 14)
        titleLbl.textColor = .black
        titleLbl.translatesAutoresizingMaskIntoConstraints = false

        let subtitleLbl = UILabel()
        subtitleLbl.text = "Export SDK log files for debugging"
        subtitleLbl.font = .systemFont(ofSize: 13)
        subtitleLbl.textColor = UIColor(hex: "#7A7A7A")
        subtitleLbl.translatesAutoresizingMaskIntoConstraints = false

        [titleLbl, subtitleLbl, logsExportButton].forEach { logsCard.addSubview($0) }

        NSLayoutConstraint.activate([
            titleLbl.topAnchor.constraint(equalTo: logsCard.topAnchor, constant: 16),
            titleLbl.leadingAnchor.constraint(equalTo: logsCard.leadingAnchor, constant: 16),

            subtitleLbl.topAnchor.constraint(equalTo: titleLbl.bottomAnchor, constant: 2),
            subtitleLbl.leadingAnchor.constraint(equalTo: logsCard.leadingAnchor, constant: 16),
            subtitleLbl.bottomAnchor.constraint(equalTo: logsCard.bottomAnchor, constant: -16),

            logsExportButton.centerYAnchor.constraint(equalTo: logsCard.centerYAnchor),
            logsExportButton.trailingAnchor.constraint(equalTo: logsCard.trailingAnchor, constant: -16),
            logsExportButton.heightAnchor.constraint(equalToConstant: 32),
            logsExportButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 64),
        ])
    }

    private func setupTokenCard() {
        tokenCard.backgroundColor = .white
        tokenCard.layer.cornerRadius = 12
        tokenCard.translatesAutoresizingMaskIntoConstraints = false

        let titleLbl = UILabel()
        titleLbl.text = "User Access Token"
        titleLbl.font = .systemFont(ofSize: 14)
        titleLbl.textColor = .black
        titleLbl.translatesAutoresizingMaskIntoConstraints = false

        tokenInfoLabel.font = .systemFont(ofSize: 13)
        tokenInfoLabel.textColor = UIColor(hex: "#7A7A7A")
        tokenInfoLabel.translatesAutoresizingMaskIntoConstraints = false
        renderTokenInfo()

        [titleLbl, tokenInfoLabel, tokenReplaceButton].forEach { tokenCard.addSubview($0) }

        NSLayoutConstraint.activate([
            titleLbl.topAnchor.constraint(equalTo: tokenCard.topAnchor, constant: 16),
            titleLbl.leadingAnchor.constraint(equalTo: tokenCard.leadingAnchor, constant: 16),

            tokenInfoLabel.topAnchor.constraint(equalTo: titleLbl.bottomAnchor, constant: 2),
            tokenInfoLabel.leadingAnchor.constraint(equalTo: tokenCard.leadingAnchor, constant: 16),
            tokenInfoLabel.trailingAnchor.constraint(lessThanOrEqualTo: tokenReplaceButton.leadingAnchor, constant: -8),
            tokenInfoLabel.bottomAnchor.constraint(equalTo: tokenCard.bottomAnchor, constant: -16),

            tokenReplaceButton.centerYAnchor.constraint(equalTo: tokenCard.centerYAnchor),
            tokenReplaceButton.trailingAnchor.constraint(equalTo: tokenCard.trailingAnchor, constant: -16),
            tokenReplaceButton.heightAnchor.constraint(equalToConstant: 32),
            tokenReplaceButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 64),
        ])
    }

    private func renderTokenInfo() {
        guard let info = JwtUtils.parse(DeviceManager.shared.userAccessToken) else {
            tokenInfoLabel.text = "Invalid token"
            return
        }
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd HH:mm"
        let exp = fmt.string(from: Date(timeIntervalSince1970: info.expSeconds))
        tokenInfoLabel.text = "\(info.userId) · expires \(exp)"
    }

    /// Paste-in a new userAccessToken. Same user (JWT sub unchanged) → applied LIVE via
    /// PlaudDeviceAgent.setUserAccessToken (SDK refreshes handshake identity + RSA keys).
    /// Different user (account switch) → persisted only; takes effect on the next cold start
    /// to avoid a half-switched runtime.
    @objc private func replaceTokenTapped() {
        let alert = UIAlertController(title: "User Access Token",
                                      message: "Paste the new token (JWT)",
                                      preferredStyle: .alert)
        alert.addTextField { $0.placeholder = "eyJhbGciOi..." }
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        alert.addAction(UIAlertAction(title: "Apply", style: .default) { [weak self] _ in
            let token = alert.textFields?.first?.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            self?.applyNewToken(token)
        })
        present(alert, animated: true)
    }

    private func applyNewToken(_ newToken: String) {
        guard let newInfo = JwtUtils.parse(newToken) else {
            showAlert(title: "User Access Token", message: "Invalid token: not a parseable JWT.")
            return
        }
        let oldInfo = JwtUtils.parse(DeviceManager.shared.userAccessToken)
        UserDefaults.standard.set(newToken, forKey: "userAccessTokenOverride")

        if let old = oldInfo, old.sub == newInfo.sub {
            // Renewal: same account — apply live (SDK re-parses handshake identity + refetches keys).
            PlaudDeviceAgent.shared.setUserAccessToken(newToken)
            renderTokenInfo()
            showAlert(title: "User Access Token",
                      message: "Token renewed for \(newInfo.userId). Applied immediately.")
        } else {
            // Account switch: persist the new identity; take effect on restart.
            RecordingStore.shared.userId = newInfo.userId
            renderTokenInfo()
            showAlert(title: "Switch Account",
                      message: "Token saved for \(newInfo.userId). Quit and relaunch the app to switch accounts.\n\nNote: a device bound to the previous account must be unpaired there before the new account can bind it.")
        }
    }

    // MARK: - API Key (transcription X-Client-Api-Key)

    private func setupApiKeyCard() {
        apiKeyCard.backgroundColor = .white
        apiKeyCard.layer.cornerRadius = 12
        apiKeyCard.translatesAutoresizingMaskIntoConstraints = false

        let titleLbl = UILabel()
        titleLbl.text = "API Key"
        titleLbl.font = .systemFont(ofSize: 14)
        titleLbl.textColor = .black
        titleLbl.translatesAutoresizingMaskIntoConstraints = false

        apiKeyInfoLabel.font = .systemFont(ofSize: 13)
        apiKeyInfoLabel.textColor = UIColor(hex: "#7A7A7A")
        apiKeyInfoLabel.translatesAutoresizingMaskIntoConstraints = false
        renderApiKeyInfo()

        [titleLbl, apiKeyInfoLabel, apiKeyReplaceButton].forEach { apiKeyCard.addSubview($0) }

        NSLayoutConstraint.activate([
            titleLbl.topAnchor.constraint(equalTo: apiKeyCard.topAnchor, constant: 16),
            titleLbl.leadingAnchor.constraint(equalTo: apiKeyCard.leadingAnchor, constant: 16),

            apiKeyInfoLabel.topAnchor.constraint(equalTo: titleLbl.bottomAnchor, constant: 2),
            apiKeyInfoLabel.leadingAnchor.constraint(equalTo: apiKeyCard.leadingAnchor, constant: 16),
            apiKeyInfoLabel.trailingAnchor.constraint(lessThanOrEqualTo: apiKeyReplaceButton.leadingAnchor, constant: -8),
            apiKeyInfoLabel.bottomAnchor.constraint(equalTo: apiKeyCard.bottomAnchor, constant: -16),

            apiKeyReplaceButton.centerYAnchor.constraint(equalTo: apiKeyCard.centerYAnchor),
            apiKeyReplaceButton.trailingAnchor.constraint(equalTo: apiKeyCard.trailingAnchor, constant: -16),
            apiKeyReplaceButton.heightAnchor.constraint(equalToConstant: 32),
            apiKeyReplaceButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 64),
        ])
    }

    private func renderApiKeyInfo() {
        let key = PlaudAPIService.shared.apiKey
        if key.isEmpty {
            apiKeyInfoLabel.text = "Not configured"
        } else if key.count <= 12 {
            apiKeyInfoLabel.text = key
        } else {
            apiKeyInfoLabel.text = "\(key.prefix(8))…\(key.suffix(4))"
        }
    }

    /// Paste-in a new transcription API key. Applied immediately — it is read on every request.
    @objc private func replaceApiKeyTapped() {
        let alert = UIAlertController(title: "API Key",
                                      message: "Paste the new API key",
                                      preferredStyle: .alert)
        alert.addTextField { $0.placeholder = "ak_..." }
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        alert.addAction(UIAlertAction(title: "Apply", style: .default) { [weak self] _ in
            let key = alert.textFields?.first?.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !key.isEmpty else { return }
            UserDefaults.standard.set(key, forKey: "apiKeyOverride")
            self?.renderApiKeyInfo()
        })
        present(alert, animated: true)
    }

    private func setupVersionCard() {
        versionCard.backgroundColor = .white
        versionCard.layer.cornerRadius = 12
        versionCard.translatesAutoresizingMaskIntoConstraints = false

        let titleLbl = UILabel()
        titleLbl.text = "Version"
        titleLbl.font = .systemFont(ofSize: 14)
        titleLbl.textColor = .black
        titleLbl.translatesAutoresizingMaskIntoConstraints = false

        let short = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
        versionValueLabel.text = "\(short) (\(build))"
        versionValueLabel.font = .systemFont(ofSize: 14)
        versionValueLabel.textColor = UIColor(hex: "#7A7A7A")
        versionValueLabel.translatesAutoresizingMaskIntoConstraints = false

        [titleLbl, versionValueLabel].forEach { versionCard.addSubview($0) }

        NSLayoutConstraint.activate([
            titleLbl.topAnchor.constraint(equalTo: versionCard.topAnchor, constant: 16),
            titleLbl.leadingAnchor.constraint(equalTo: versionCard.leadingAnchor, constant: 16),
            titleLbl.bottomAnchor.constraint(equalTo: versionCard.bottomAnchor, constant: -16),

            versionValueLabel.centerYAnchor.constraint(equalTo: titleLbl.centerYAnchor),
            versionValueLabel.trailingAnchor.constraint(equalTo: versionCard.trailingAnchor, constant: -16),
        ])
    }

    // MARK: - Server Environment (production / test domain)

    private func setupEnvCard() {
        envCard.backgroundColor = .white
        envCard.layer.cornerRadius = 12
        envCard.translatesAutoresizingMaskIntoConstraints = false

        let titleLbl = UILabel()
        titleLbl.text = "Server Environment"
        titleLbl.font = .systemFont(ofSize: 14)
        titleLbl.textColor = .black
        titleLbl.translatesAutoresizingMaskIntoConstraints = false

        envInfoLabel.font = .systemFont(ofSize: 13)
        envInfoLabel.textColor = UIColor(hex: "#7A7A7A")
        envInfoLabel.translatesAutoresizingMaskIntoConstraints = false
        renderEnvInfo()

        [titleLbl, envInfoLabel, envSwitchButton].forEach { envCard.addSubview($0) }

        NSLayoutConstraint.activate([
            titleLbl.topAnchor.constraint(equalTo: envCard.topAnchor, constant: 16),
            titleLbl.leadingAnchor.constraint(equalTo: envCard.leadingAnchor, constant: 16),

            envInfoLabel.topAnchor.constraint(equalTo: titleLbl.bottomAnchor, constant: 2),
            envInfoLabel.leadingAnchor.constraint(equalTo: envCard.leadingAnchor, constant: 16),
            envInfoLabel.trailingAnchor.constraint(lessThanOrEqualTo: envSwitchButton.leadingAnchor, constant: -8),
            envInfoLabel.bottomAnchor.constraint(equalTo: envCard.bottomAnchor, constant: -16),

            envSwitchButton.centerYAnchor.constraint(equalTo: envCard.centerYAnchor),
            envSwitchButton.trailingAnchor.constraint(equalTo: envCard.trailingAnchor, constant: -16),
            envSwitchButton.heightAnchor.constraint(equalToConstant: 32),
            envSwitchButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 64),
        ])
    }

    private func renderEnvInfo() {
        let domain = RecordingStore.shared.activeServerDomain
        envInfoLabel.text = "\(RecordingStore.serverEnvironmentLabel(for: domain)) · \(domain)"
    }

    /// Switch the server domain (SDK customDomain and all API base URLs derive from it).
    /// Persisted only — the SDK is initialized once at app start, so the new domain takes
    /// effect on the next cold start.
    @objc private func switchEnvTapped() {
        let sheet = UIAlertController(title: "Server Environment", message: nil, preferredStyle: .actionSheet)
        let current = RecordingStore.shared.activeServerDomain
        for (label, domain) in RecordingStore.serverEnvironments {
            let mark = domain == current ? " ✓" : ""
            sheet.addAction(UIAlertAction(title: "\(label) (\(domain))\(mark)", style: .default) { [weak self] _ in
                guard domain != current else { return }
                RecordingStore.shared.serverDomainOverride = domain
                self?.renderEnvInfo()
                self?.showAlert(title: "Server Environment",
                                message: "Server switched to \(domain). Quit and relaunch the app to apply.")
            })
        }
        sheet.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        sheet.popoverPresentationController?.sourceView = envSwitchButton
        present(sheet, animated: true)
    }

    private func showAlert(title: String, message: String) {
        let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default))
        present(alert, animated: true)
    }

    // MARK: - SDK Bindings

    private func setupBindings() {
        deviceManager.connectedDevicePublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] device in
                guard let self = self else { return }
                self.connectedDevice = device
                if let fw = device?.firmwareVersion, !fw.isEmpty {
                    self.fwVersionLabel.text = "Version \(fw)"
                } else {
                    self.fwVersionLabel.text = "Version --"
                }
                // Hide Update button during OTA
                self.fwUpdateButton.isHidden = device?.latestFirmwareVersion == nil
            }
            .store(in: &cancellables)

        // Check firmware update after connection
        deviceManager.checkFirmwareUpdate { [weak self] result in
            DispatchQueue.main.async {
                if result.hasUpdate {
                    self?.fwUpdateButton.isHidden = false
                    self?.connectedDevice?.latestFirmwareVersion = result.latestVersion
                }
            }
        }
    }

    // MARK: - Actions

    @objc private func firmwareUpdateTapped() {
        let name = connectedDevice?.displayName ?? "Plaud Device"
        let sheet = FirmwareUpdateSheetViewController(deviceManager: deviceManager, deviceName: name)
        if #available(iOS 16.0, *) {
            sheet.sheetPresentationController?.detents = [.custom { _ in 380 }]
            sheet.sheetPresentationController?.preferredCornerRadius = 12
        } else if #available(iOS 15.0, *) {
            sheet.sheetPresentationController?.detents = [.medium()]
            sheet.sheetPresentationController?.preferredCornerRadius = 12
        }
        sheet.onComplete = { [weak self] success, message in
            if success {
                self?.fwUpdateButton.isHidden = true
            } else {
                let alert = UIAlertController(title: "Update Failed", message: message, preferredStyle: .alert)
                alert.addAction(UIAlertAction(title: "OK", style: .default))
                self?.present(alert, animated: true)
            }
        }
        present(sheet, animated: true)
    }

    @objc private func signOutTapped() {
        // Sign-out unpairs, so it strands an in-progress recording exactly like Unpair does
        // (PLA2-401) — same refusal here, otherwise the guard is trivially bypassed.
        if RecordingManager.shared.stateSubject.value.isActive {
            let busy = UIAlertController(
                title: "Device Is Recording",
                message: DevicePanelViewController.recordingInProgressMessage,
                preferredStyle: .alert
            )
            busy.addAction(UIAlertAction(title: "OK", style: .default))
            present(busy, animated: true)
            return
        }
        let alert = UIAlertController(
            title: "Sign Out",
            message: "This will disconnect and unpair your device.",
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: "Sign Out", style: .destructive) { [weak self] _ in
            self?.deviceManager.unpair()
            // Sign-out returns to onboarding for real — drop the "connect later" shortcut too.
            RecordingStore.shared.hasSkippedOnboarding = false
            let nav = UINavigationController(rootViewController: WelcomeViewController())
            self?.view.window?.rootViewController = nav
        })
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        present(alert, animated: true)
    }

    @objc private func exportLogsTapped() {
        // The SDK auto-redirects its logs to Documents/PlaudLogs/plaud.log (with rotation);
        // exportEncryptedLogFile() packages them into an encrypted .plaud bundle and throws a
        // PlaudLogExportError with a concrete reason on failure (no more silent nil).
        do {
            let logFileURL = try PlaudLogEncryption.exportEncryptedLogFile() as URL
            // The .plaud bundle is a standalone copy, so clear the source logs now: each export
            // then starts a fresh window and stale rotated segments don't pile up.
            PlaudLogRedirect.deleteAllLogFiles()
            let ac = UIActivityViewController(activityItems: [logFileURL], applicationActivities: nil)
            ac.popoverPresentationController?.sourceView = logsExportButton
            present(ac, animated: true)
        } catch {
            let alert = UIAlertController(
                title: "Export Failed",
                message: error.localizedDescription,
                preferredStyle: .alert
            )
            alert.addAction(UIAlertAction(title: "OK", style: .default))
            present(alert, animated: true)
        }
    }
}
