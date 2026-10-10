import UIKit
import Combine
import PlaudDeviceBasicSDK

/// Device management page (full-screen push, not sheet)
final class DevicePanelViewController: UIViewController {

    private var device: PlaudDevice
    private let deviceManager: DeviceManagerProtocol
    private var cancellables = Set<AnyCancellable>()

    init(device: PlaudDevice, deviceManager: DeviceManagerProtocol) {
        self.device = device
        self.deviceManager = deviceManager
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError() }

    // MARK: - Views

    private let scrollView = UIScrollView()
    private let contentView = UIView()

    // Card 1 — Device Info
    private let infoCard = UIView()
    private let nameValueLabel = UILabel()
    private let snValueLabel = UILabel()
    private let fwVersionLabel = UILabel()
    private lazy var updateButton: UIButton = {
        let btn = UIButton(type: .custom)
        btn.setTitle("Update", for: .normal)
        btn.setTitleColor(.white, for: .normal)
        btn.titleLabel?.font = .systemFont(ofSize: 14, weight: .semibold)
        btn.backgroundColor = .black
        btn.layer.cornerRadius = 12
        btn.translatesAutoresizingMaskIntoConstraints = false
        btn.addTarget(self, action: #selector(updateFirmware), for: .touchUpInside)
        return btn
    }()

    // Card 1.5 — iBeacon wake-up ("Seamless Reconnect", SDK v1.0.15).
    // Appears dimmed while the firmware capability is still unknown and becomes
    // interactive once it lands; removed if the firmware turns out not to support it
    // (isBeaconWakeupSupported is false while disconnected — never treat it as
    // an offline capability table).
    private let beaconCard = UIView()
    private let beaconToggle = PlaudToggle()
    private let beaconTitleLabel = UILabel()
    private let beaconSubtitleLabel = UILabel()
    /// Capability still unknown — card is visible but inert (see updateBeaconAvailability).
    private var beaconAwaitingCapability = false
    /// Invalidates an in-flight capability watch when a newer one starts.
    private var beaconPollToken = 0
    private var actionsTopToInfo: NSLayoutConstraint!
    private var actionsTopToBeacon: NSLayoutConstraint!

    // Card 2 — Actions
    private let actionsCard = UIView()
    private lazy var disconnectButton: UIButton = {
        makeOutlineButton(title: "Disconnect", borderColor: UIColor(hex: "#ADADAD"), textColor: .black)
    }()
    private lazy var unpairButton: UIButton = {
        makeOutlineButton(title: "Unpair", borderColor: UIColor(hex: "#FF503F"), textColor: UIColor(hex: "#FF503F"))
    }()

    // MARK: - Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = PlaudTheme.backgroundPrimary
        setupNavBar()
        setupLayout()
        setupBindings()
        populateData()
        updateBeaconAvailability()
    }

    // MARK: - Navigation Bar

    private func setupNavBar() {
        navigationController?.setNavigationBarHidden(false, animated: true)
        navigationItem.title = device.displayName
        let titleFont = UIFont.systemFont(ofSize: 16, weight: .semibold)
        navigationController?.navigationBar.titleTextAttributes = [.font: titleFont]

        let backBtn = UIButton(type: .system)
        backBtn.setImage(UIImage(systemName: "chevron.left", withConfiguration: UIImage.SymbolConfiguration(pointSize: 17, weight: .medium)), for: .normal)
        backBtn.tintColor = .black
        backBtn.addTarget(self, action: #selector(backTapped), for: .touchUpInside)
        navigationItem.leftBarButtonItem = UIBarButtonItem(customView: backBtn)
    }

    // MARK: - Layout

    private func setupLayout() {
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        contentView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(scrollView)
        scrollView.addSubview(contentView)

        setupInfoCard()
        setupActionsCard()

        setupBeaconCard()
        [infoCard, beaconCard, actionsCard].forEach { contentView.addSubview($0) }

        actionsTopToInfo = actionsCard.topAnchor.constraint(equalTo: infoCard.bottomAnchor, constant: 24)
        actionsTopToBeacon = actionsCard.topAnchor.constraint(equalTo: beaconCard.bottomAnchor, constant: 24)
        actionsTopToInfo.isActive = true

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

            infoCard.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 24),
            infoCard.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 24),
            infoCard.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -24),

            beaconCard.topAnchor.constraint(equalTo: infoCard.bottomAnchor, constant: 24),
            beaconCard.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 24),
            beaconCard.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -24),

            actionsCard.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 24),
            actionsCard.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -24),
            actionsCard.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -40),
        ])
    }

    private func setupInfoCard() {
        infoCard.backgroundColor = .white
        infoCard.layer.cornerRadius = 12
        infoCard.translatesAutoresizingMaskIntoConstraints = false

        let nameRow = makeInfoRow(label: "Device name", valueLabel: nameValueLabel)
        let sep1 = makeSeparator()
        let snRow = makeInfoRow(label: "Serial number", valueLabel: snValueLabel)
        let sep2 = makeSeparator()
        let fwRow = makeFirmwareRow()

        [nameRow, sep1, snRow, sep2, fwRow].forEach { infoCard.addSubview($0) }

        NSLayoutConstraint.activate([
            nameRow.topAnchor.constraint(equalTo: infoCard.topAnchor),
            nameRow.leadingAnchor.constraint(equalTo: infoCard.leadingAnchor),
            nameRow.trailingAnchor.constraint(equalTo: infoCard.trailingAnchor),
            nameRow.heightAnchor.constraint(equalToConstant: 52),

            sep1.topAnchor.constraint(equalTo: nameRow.bottomAnchor),
            sep1.leadingAnchor.constraint(equalTo: infoCard.leadingAnchor, constant: 16),
            sep1.trailingAnchor.constraint(equalTo: infoCard.trailingAnchor, constant: -16),

            snRow.topAnchor.constraint(equalTo: sep1.bottomAnchor),
            snRow.leadingAnchor.constraint(equalTo: infoCard.leadingAnchor),
            snRow.trailingAnchor.constraint(equalTo: infoCard.trailingAnchor),
            snRow.heightAnchor.constraint(equalToConstant: 52),

            sep2.topAnchor.constraint(equalTo: snRow.bottomAnchor),
            sep2.leadingAnchor.constraint(equalTo: infoCard.leadingAnchor, constant: 16),
            sep2.trailingAnchor.constraint(equalTo: infoCard.trailingAnchor, constant: -16),

            fwRow.topAnchor.constraint(equalTo: sep2.bottomAnchor),
            fwRow.leadingAnchor.constraint(equalTo: infoCard.leadingAnchor),
            fwRow.trailingAnchor.constraint(equalTo: infoCard.trailingAnchor),
            fwRow.bottomAnchor.constraint(equalTo: infoCard.bottomAnchor),
        ])
    }

    private func setupActionsCard() {
        actionsCard.backgroundColor = .white
        actionsCard.layer.cornerRadius = 12
        actionsCard.translatesAutoresizingMaskIntoConstraints = false

        let disconnectRow = makeActionRow(
            title: "Disconnect device",
            subtitle: "Temporarily disconnect this device.",
            button: disconnectButton
        )
        let sep = makeSeparator()
        let unpairRow = makeActionRow(
            title: "Unpair device",
            subtitle: "Remove this device from your account.",
            button: unpairButton
        )

        [disconnectRow, sep, unpairRow].forEach { actionsCard.addSubview($0) }

        NSLayoutConstraint.activate([
            disconnectRow.topAnchor.constraint(equalTo: actionsCard.topAnchor),
            disconnectRow.leadingAnchor.constraint(equalTo: actionsCard.leadingAnchor),
            disconnectRow.trailingAnchor.constraint(equalTo: actionsCard.trailingAnchor),

            sep.topAnchor.constraint(equalTo: disconnectRow.bottomAnchor),
            sep.leadingAnchor.constraint(equalTo: actionsCard.leadingAnchor, constant: 16),
            sep.trailingAnchor.constraint(equalTo: actionsCard.trailingAnchor, constant: -16),

            unpairRow.topAnchor.constraint(equalTo: sep.bottomAnchor),
            unpairRow.leadingAnchor.constraint(equalTo: actionsCard.leadingAnchor),
            unpairRow.trailingAnchor.constraint(equalTo: actionsCard.trailingAnchor),
            unpairRow.bottomAnchor.constraint(equalTo: actionsCard.bottomAnchor),
        ])

        disconnectButton.addTarget(self, action: #selector(disconnectTapped), for: .touchUpInside)
        unpairButton.addTarget(self, action: #selector(unpairTapped), for: .touchUpInside)
    }

    // MARK: - Data

    private func populateData() {
        nameValueLabel.text = device.displayName
        snValueLabel.text = device.serialNumber
        fwVersionLabel.text = device.firmwareVersion.isEmpty ? "--" : device.firmwareVersion
        updateButton.isHidden = device.latestFirmwareVersion == nil
    }

    private func setupBindings() {
        deviceManager.connectedDevicePublisher
            .receive(on: DispatchQueue.main)
            .compactMap { $0 }
            .sink { [weak self] updated in
                self?.device = updated
                self?.populateData()
                self?.updateBeaconAvailability()
            }
            .store(in: &cancellables)

        // Switch state read back from the device (reads and writes share it).
        // The device-side flag alone does not mean the feature works: region monitoring
        // needs the phone's Always location permission, and that is lost whenever the app
        // is reinstalled while the device keeps its flag set. Show the switch on only when
        // both halves are in place, otherwise it reads as enabled while nothing can wake us.
        DeviceManager.shared.beaconWakeupEnabledPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] value in
                self?.beaconToggle.isOn = value == 1 && PlaudDeviceAgent.shared.isBeaconLocationAlwaysGranted
            }
            .store(in: &cancellables)

        // Always permission revoked in system settings → monitoring is torn
        // down, mirror it on the switch.
        DeviceManager.shared.beaconAlwaysRevokedPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in
                self?.beaconToggle.isOn = false
            }
            .store(in: &cancellables)
    }

    // MARK: - iBeacon Wake-up ("Seamless Reconnect")

    private func setupBeaconCard() {
        beaconCard.backgroundColor = .white
        beaconCard.layer.cornerRadius = 12
        beaconCard.isHidden = true
        beaconCard.translatesAutoresizingMaskIntoConstraints = false

        let titleLabel = beaconTitleLabel
        titleLabel.text = "Seamless Reconnect"
        titleLabel.font = .systemFont(ofSize: 14)
        titleLabel.textColor = .black
        titleLabel.translatesAutoresizingMaskIntoConstraints = false

        let subtitleLabel = beaconSubtitleLabel
        subtitleLabel.text = "Wake the app in the background and auto-reconnect when your device is nearby"
        subtitleLabel.font = .systemFont(ofSize: 13)
        subtitleLabel.textColor = UIColor(hex: "#7A7A7A")
        subtitleLabel.numberOfLines = 2
        subtitleLabel.translatesAutoresizingMaskIntoConstraints = false

        beaconToggle.isOn = RecordingStore.shared.isBeaconWakeupEnabled(sn: device.serialNumber)
            && PlaudDeviceAgent.shared.isBeaconLocationAlwaysGranted
        beaconToggle.translatesAutoresizingMaskIntoConstraints = false
        beaconToggle.onToggle = { [weak self] isOn in
            self?.beaconToggleChanged(isOn)
        }

        [titleLabel, subtitleLabel, beaconToggle].forEach { beaconCard.addSubview($0) }

        NSLayoutConstraint.activate([
            titleLabel.topAnchor.constraint(equalTo: beaconCard.topAnchor, constant: 16),
            titleLabel.leadingAnchor.constraint(equalTo: beaconCard.leadingAnchor, constant: 16),

            subtitleLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 2),
            subtitleLabel.leadingAnchor.constraint(equalTo: beaconCard.leadingAnchor, constant: 16),
            subtitleLabel.trailingAnchor.constraint(equalTo: beaconToggle.leadingAnchor, constant: -12),
            subtitleLabel.bottomAnchor.constraint(equalTo: beaconCard.bottomAnchor, constant: -16),

            beaconToggle.centerYAnchor.constraint(equalTo: beaconCard.centerYAnchor),
            beaconToggle.trailingAnchor.constraint(equalTo: beaconCard.trailingAnchor, constant: -16),
            beaconToggle.widthAnchor.constraint(equalToConstant: 48),
            beaconToggle.heightAnchor.constraint(equalToConstant: 26),
        ])
    }

    /// The capability flag only turns true once the device answers the NewFeature
    /// query, which lands a few seconds after bind, and it reads false whenever the
    /// device is disconnected. The SDK exposes no "capability ready" callback, so the
    /// panel shows the card in a dimmed, non-interactive waiting state and polls;
    /// the switch becomes usable the moment the capability lands. If it never lands
    /// within the window the firmware genuinely lacks beacon support (NewFeature
    /// bit7) and the card is removed.
    private func updateBeaconAvailability() {
        // Supersede any watch already in flight so device updates can't stack polls.
        beaconPollToken += 1
        pollBeaconCapability(retriesLeft: 20, token: beaconPollToken)
    }

    private func pollBeaconCapability(retriesLeft: Int, token: Int) {
        guard token == beaconPollToken else { return } // superseded by a newer watch
        let supported = PlaudDeviceAgent.shared.isBeaconWakeupSupported
        AppLog.log("[DevicePanel] beacon wakeup supported=\(supported) fw=\(device.firmwareVersion) retriesLeft=\(retriesLeft)", level: "BEACON")

        if supported {
            showBeaconCard(waiting: false)
            PlaudDeviceAgent.shared.readIBeaconWakeupEnabled()
            return
        }
        // Once resolved as supported the card stays — a later disconnect flips the
        // flag back to false but must not tear down a switch the user is using.
        guard beaconCard.isHidden || beaconAwaitingCapability else { return }
        // Only worth waiting while a device is connected; otherwise it can never arrive.
        // Firmware older than 1.7.0 never reports the capability, so showing the dimmed
        // placeholder there would flash a card that then vanishes.
        guard retriesLeft > 0,
              firmwareMaySupportBeacon,
              case .connected = DeviceManager.shared.currentConnectionState else {
            hideBeaconCard()
            return
        }
        showBeaconCard(waiting: true)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.pollBeaconCapability(retriesLeft: retriesLeft - 1, token: token)
        }
    }

    /// Beacon wake-up needs NotePro firmware 1.7.0 or newer. The capability flag itself is
    /// authoritative but only arrives seconds after connecting, so the version gates whether
    /// it is worth showing the dimmed placeholder while we wait. An unknown or unparseable
    /// version is treated as unsupported — better no card than one that appears and vanishes.
    private var firmwareMaySupportBeacon: Bool {
        let digits = device.firmwareVersion.drop { !$0.isNumber }   // "V1.7.0" / "T1.7.0" → "1.7.0"
        let parts = digits.split(separator: ".").compactMap { Int($0) }
        guard parts.count == 3 else { return false }
        return (parts[0], parts[1], parts[2]) >= (1, 7, 0)
    }

    /// waiting = capability not confirmed yet: visible but dimmed and inert.
    private func showBeaconCard(waiting: Bool) {
        beaconAwaitingCapability = waiting
        if beaconCard.isHidden {
            beaconCard.isHidden = false
            actionsTopToInfo.isActive = false
            actionsTopToBeacon.isActive = true
        }
        beaconTitleLabel.alpha = waiting ? 0.4 : 1
        beaconSubtitleLabel.alpha = waiting ? 0.4 : 1
        beaconToggle.alpha = waiting ? 0.4 : 1
        beaconToggle.isUserInteractionEnabled = !waiting
    }

    private func hideBeaconCard() {
        beaconAwaitingCapability = false
        guard !beaconCard.isHidden else { return }
        beaconCard.isHidden = true
        actionsTopToBeacon.isActive = false
        actionsTopToInfo.isActive = true
    }

    private func beaconToggleChanged(_ isOn: Bool) {
        guard isOn else {
            PlaudDeviceAgent.shared.setIBeaconWakeupEnabled(value: 0)
            return
        }
        // Turning on requires the Always location permission (two-stage flow).
        if PlaudDeviceAgent.shared.isBeaconLocationAlwaysGranted {
            PlaudDeviceAgent.shared.setIBeaconWakeupEnabled(value: 1)
        } else if PlaudDeviceAgent.shared.canRequestBeaconLocationAlwaysUpgrade {
            PlaudDeviceAgent.shared.requestBeaconLocationAlwaysPermission { [weak self] granted in
                DispatchQueue.main.async {
                    if granted {
                        PlaudDeviceAgent.shared.setIBeaconWakeupEnabled(value: 1)
                    } else {
                        self?.beaconToggle.isOn = false
                    }
                }
            }
        } else {
            // The one-shot Always upgrade prompt was already spent for this
            // install — the only remaining path is the system Settings app.
            beaconToggle.isOn = false
            presentBeaconSettingsAlert()
        }
    }

    private func presentBeaconSettingsAlert() {
        let alert = UIAlertController(
            title: "Allow Location Access",
            message: "Seamless Reconnect needs location set to \"Always\" so the system can wake the app when your device is nearby. Enable it in Settings > Privacy > Location Services.",
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: "Open Settings", style: .default) { _ in
            if let url = URL(string: UIApplication.openSettingsURLString) {
                UIApplication.shared.open(url)
            }
        })
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        present(alert, animated: true)
    }

    // MARK: - Factory Methods

    private func makeInfoRow(label: String, valueLabel: UILabel) -> UIView {
        let row = UIView()
        row.translatesAutoresizingMaskIntoConstraints = false

        let titleLabel = UILabel()
        titleLabel.text = label
        titleLabel.font = .systemFont(ofSize: 14)
        titleLabel.textColor = .black
        titleLabel.translatesAutoresizingMaskIntoConstraints = false

        valueLabel.font = .systemFont(ofSize: 14)
        valueLabel.textColor = UIColor(hex: "#7A7A7A")
        valueLabel.textAlignment = .right
        valueLabel.translatesAutoresizingMaskIntoConstraints = false

        [titleLabel, valueLabel].forEach { row.addSubview($0) }
        NSLayoutConstraint.activate([
            titleLabel.leadingAnchor.constraint(equalTo: row.leadingAnchor, constant: 16),
            titleLabel.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            valueLabel.trailingAnchor.constraint(equalTo: row.trailingAnchor, constant: -16),
            valueLabel.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            valueLabel.leadingAnchor.constraint(greaterThanOrEqualTo: titleLabel.trailingAnchor, constant: 16),
        ])
        return row
    }

    private func makeFirmwareRow() -> UIView {
        let row = UIView()
        row.translatesAutoresizingMaskIntoConstraints = false

        let titleLabel = UILabel()
        titleLabel.text = "Firmware update"
        titleLabel.font = .systemFont(ofSize: 14)
        titleLabel.textColor = .black
        titleLabel.translatesAutoresizingMaskIntoConstraints = false

        fwVersionLabel.font = .systemFont(ofSize: 14)
        fwVersionLabel.textColor = UIColor(hex: "#7A7A7A")
        fwVersionLabel.translatesAutoresizingMaskIntoConstraints = false

        [titleLabel, fwVersionLabel, updateButton].forEach { row.addSubview($0) }
        NSLayoutConstraint.activate([
            titleLabel.topAnchor.constraint(equalTo: row.topAnchor, constant: 16),
            titleLabel.leadingAnchor.constraint(equalTo: row.leadingAnchor, constant: 16),
            fwVersionLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 4),
            fwVersionLabel.leadingAnchor.constraint(equalTo: row.leadingAnchor, constant: 16),
            fwVersionLabel.bottomAnchor.constraint(equalTo: row.bottomAnchor, constant: -16),
            updateButton.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            updateButton.trailingAnchor.constraint(equalTo: row.trailingAnchor, constant: -16),
            updateButton.heightAnchor.constraint(equalToConstant: 32),
            updateButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 64),
        ])
        updateButton.contentEdgeInsets = UIEdgeInsets(top: 0, left: 16, bottom: 0, right: 16)
        return row
    }

    private func makeActionRow(title: String, subtitle: String, button: UIButton) -> UIView {
        let row = UIView()
        row.translatesAutoresizingMaskIntoConstraints = false

        let titleLabel = UILabel()
        titleLabel.text = title
        titleLabel.font = .systemFont(ofSize: 14)
        titleLabel.textColor = .black
        titleLabel.translatesAutoresizingMaskIntoConstraints = false

        let subtitleLabel = UILabel()
        subtitleLabel.text = subtitle
        subtitleLabel.font = .systemFont(ofSize: 14)
        subtitleLabel.textColor = UIColor(hex: "#7A7A7A")
        subtitleLabel.numberOfLines = 2
        subtitleLabel.translatesAutoresizingMaskIntoConstraints = false

        [titleLabel, subtitleLabel, button].forEach { row.addSubview($0) }
        NSLayoutConstraint.activate([
            titleLabel.topAnchor.constraint(equalTo: row.topAnchor, constant: 16),
            titleLabel.leadingAnchor.constraint(equalTo: row.leadingAnchor, constant: 16),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: button.leadingAnchor, constant: -12),
            subtitleLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 4),
            subtitleLabel.leadingAnchor.constraint(equalTo: row.leadingAnchor, constant: 16),
            subtitleLabel.trailingAnchor.constraint(lessThanOrEqualTo: button.leadingAnchor, constant: -12),
            subtitleLabel.bottomAnchor.constraint(equalTo: row.bottomAnchor, constant: -16),
            button.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            button.trailingAnchor.constraint(equalTo: row.trailingAnchor, constant: -16),
            button.heightAnchor.constraint(equalToConstant: 32),
            button.widthAnchor.constraint(greaterThanOrEqualToConstant: 64),
        ])
        return row
    }

    private func makeSeparator() -> UIView {
        let v = UIView()
        v.backgroundColor = UIColor(hex: "#EBEBEB")
        v.translatesAutoresizingMaskIntoConstraints = false
        v.heightAnchor.constraint(equalToConstant: 1).isActive = true
        return v
    }

    private func makeOutlineButton(title: String, borderColor: UIColor, textColor: UIColor) -> UIButton {
        let btn = UIButton(type: .custom)
        btn.setTitle(title, for: .normal)
        btn.setTitleColor(textColor, for: .normal)
        btn.titleLabel?.font = .systemFont(ofSize: 14)
        btn.layer.cornerRadius = 12
        btn.layer.borderWidth = 1
        btn.layer.borderColor = borderColor.cgColor
        btn.backgroundColor = .white
        btn.contentEdgeInsets = UIEdgeInsets(top: 0, left: 16, bottom: 0, right: 16)
        btn.translatesAutoresizingMaskIntoConstraints = false
        return btn
    }

    // MARK: - Actions

    @objc private func backTapped() {
        navigationController?.popViewController(animated: true)
    }

    @objc private func updateFirmware() {
        let name = device.displayName
        let sheet = FirmwareUpdateSheetViewController(deviceManager: deviceManager, deviceName: name)
        if #available(iOS 16.0, *) {
            sheet.sheetPresentationController?.detents = [.custom { _ in 380 }]
            sheet.sheetPresentationController?.preferredCornerRadius = 12
        } else if #available(iOS 15.0, *) {
            sheet.sheetPresentationController?.detents = [.medium()]
            sheet.sheetPresentationController?.preferredCornerRadius = 12
        }
        sheet.onComplete = { [weak self] success, message in
            if !success {
                let alert = UIAlertController(title: "Update Failed", message: message, preferredStyle: .alert)
                alert.addAction(UIAlertAction(title: "OK", style: .default))
                self?.present(alert, animated: true)
            }
        }
        present(sheet, animated: true)
    }

    @objc private func disconnectTapped() {
        let alert = UIAlertController(title: "Disconnect", message: "The device will stay paired.", preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "Disconnect", style: .destructive) { [weak self] _ in
            self?.deviceManager.disconnect()
            self?.navigationController?.popViewController(animated: true)
        })
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        present(alert, animated: true)
    }

    @objc private func unpairTapped() {
        // Unpairing mid-recording strands the in-progress file: the device keeps writing it but we
        // lose the right to download it, so the recording is silently lost (PLA2-401).
        if RecordingManager.shared.stateSubject.value.isActive {
            presentRecordingInProgressAlert()
            return
        }
        let alert = UIAlertController(title: "Unpair Device", message: "You'll need to pair again to use it.", preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "Unpair", style: .destructive) { [weak self] _ in
            guard let self else { return }
            self.deviceManager.unpair()
            // Multi-device aware (mirrors Android): unpairing ONE device must not throw the user
            // back to onboarding while other paired devices are still usable — pop to Home instead
            // and let it reconnect the next device. Only a now-empty list means onboarding again.
            if self.deviceManager.getPairedDevices().isEmpty {
                let nav = UINavigationController(rootViewController: WelcomeViewController())
                self.view.window?.rootViewController = nav
            } else {
                self.navigationController?.popViewController(animated: true)
            }
        })
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        present(alert, animated: true)
    }

    /// Shared refusal for destructive actions while the device still holds an unfinished recording.
    static let recordingInProgressMessage =
        "Stop the recording first — unpairing now would lose the recording in progress."

    private func presentRecordingInProgressAlert() {
        let alert = UIAlertController(
            title: "Device Is Recording",
            message: Self.recordingInProgressMessage,
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: "OK", style: .default))
        present(alert, animated: true)
    }
}
