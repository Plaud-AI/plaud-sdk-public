import UIKit
import Combine

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

        [titleLabel, firmwareCard, signOutButton].forEach { contentView.addSubview($0) }

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

            signOutButton.topAnchor.constraint(equalTo: firmwareCard.bottomAnchor, constant: 24),
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
        let name = connectedDevice?.name ?? "Plaud Device"
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
        let alert = UIAlertController(
            title: "Sign Out",
            message: "This will disconnect and unpair your device.",
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: "Sign Out", style: .destructive) { [weak self] _ in
            self?.deviceManager.unpair()
            let nav = UINavigationController(rootViewController: WelcomeViewController())
            self?.view.window?.rootViewController = nav
        })
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        present(alert, animated: true)
    }
}
