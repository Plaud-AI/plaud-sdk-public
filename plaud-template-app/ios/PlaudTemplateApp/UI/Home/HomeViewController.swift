import UIKit
import Combine

/// Home page: Device card + Recording trigger card + Recent Files
final class HomeViewController: UIViewController {

    // MARK: - SDK Integration
    private let deviceManager: DeviceManagerProtocol = DeviceManager.shared
    private let syncManager: SyncManagerProtocol = SyncManager.shared
    private let recordingManager: RecordingManagerProtocol = RecordingManager.shared
    private var cancellables = Set<AnyCancellable>()

    // MARK: - Views
    private let scrollView = UIScrollView()
    private let contentView = UIView()

    /// Page large title "Home"
    private let titleLabel: UILabel = {
        let l = UILabel()
        l.text = "Home"
        l.font = .systemFont(ofSize: 44, weight: .light)
        l.textColor = .black
        l.translatesAutoresizingMaskIntoConstraints = false
        return l
    }()

    private let deviceCard = DeviceCardView()
    private let recordCard = RecordingTriggerCardView()
    private let bannerStack: UIStackView = {
        let s = UIStackView()
        s.axis = .vertical
        s.spacing = 8
        s.translatesAutoresizingMaskIntoConstraints = false
        return s
    }()
    private let syncBanner = SyncBannerView()
    private let recordingBanner = RecordingBannerView()
    private let recentFilesSection = RecentFilesSectionView()

    // MARK: - State
    private var currentConnectedDevice: PlaudDevice?

    // MARK: - Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = PlaudTheme.backgroundPrimary
        navigationController?.setNavigationBarHidden(true, animated: false)
        setupLayout()
        setupBindings()
        setupAutoSync()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        // Refresh paired device list when returning from Add Device / Settings
        let paired = DeviceManager.shared.getPairedDevices()
        let activeSN = currentConnectedDevice?.serialNumber
        deviceCard.configurePairedDevices(paired, activeSN: activeSN)
    }

    // MARK: - Layout

    private func setupLayout() {
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.alwaysBounceVertical = true
        scrollView.showsVerticalScrollIndicator = false
        view.addSubview(scrollView)

        contentView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.addSubview(contentView)

        deviceCard.translatesAutoresizingMaskIntoConstraints = false
        deviceCard.onExpandToggle = { [weak self] in self?.view.layoutIfNeeded() }
        deviceCard.onManageTapped = { [weak self] in self?.manageTapped() }
        deviceCard.onSwitchDevice = { [weak self] sn in self?.deviceManager.switchDevice(sn: sn) }
        deviceCard.onAddDevice = { [weak self] in self?.addDevice() }

        recordCard.translatesAutoresizingMaskIntoConstraints = false
        recordCard.onTapped = { [weak self] in self?.openRecording() }

        syncBanner.translatesAutoresizingMaskIntoConstraints = false
        syncBanner.isHidden = true
        syncBanner.onFastTransferTapped = { [weak self] in self?.showFastTransferDialog() }

        recordingBanner.translatesAutoresizingMaskIntoConstraints = false
        recordingBanner.isHidden = true
        recordingBanner.onTapped = { [weak self] in self?.openRecording() }

        recentFilesSection.translatesAutoresizingMaskIntoConstraints = false
        recentFilesSection.onFileTapped = { [weak self] file in self?.openFile(file) }

        bannerStack.addArrangedSubview(syncBanner)
        bannerStack.addArrangedSubview(recordingBanner)

        [titleLabel, deviceCard, recordCard, bannerStack, recentFilesSection]
            .forEach { contentView.addSubview($0) }

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

            // "Home" large title
            titleLabel.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 16),
            titleLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 24),

            // Device card
            deviceCard.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 40),
            deviceCard.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 24),
            deviceCard.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -24),

            // Recording trigger card
            recordCard.topAnchor.constraint(equalTo: deviceCard.bottomAnchor, constant: 12),
            recordCard.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 24),
            recordCard.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -24),
            recordCard.heightAnchor.constraint(equalToConstant: 142),

            // Banner area (StackView: auto-collapses to 0 height when hidden)
            bannerStack.topAnchor.constraint(equalTo: recordCard.bottomAnchor, constant: 12),
            bannerStack.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 24),
            bannerStack.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -24),

            // Recent Files always follows bannerStack
            // When banner hidden: bannerStack height=0, spacing=12+28=40pt (matches Figma)
            // When banner visible: bannerStack has height, recentFiles pushed down
            recentFilesSection.topAnchor.constraint(equalTo: bannerStack.bottomAnchor, constant: 28),
            recentFilesSection.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 24),
            recentFilesSection.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -24),
            recentFilesSection.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -120),
        ])
    }

    // MARK: - SDK Bindings

    private func setupBindings() {
        deviceManager.connectedDevicePublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] device in
                self?.currentConnectedDevice = device
                self?.deviceCard.configure(with: device)
                // Update paired device list
                let paired = DeviceManager.shared.getPairedDevices()
                self?.deviceCard.configurePairedDevices(paired, activeSN: device?.serialNumber)
            }
            .store(in: &cancellables)

        // Trigger sync when device transitions from nil to non-nil (actually connected)
        // Trigger file sync after device connects (on every reconnect, including WiFi→BLE switch)
        deviceManager.connectionStatePublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] state in
                guard case .connected = state else { return }
                // Skip sync while device is recording (getFileList would fail)
                guard case .idle = RecordingManager.shared.stateSubject.value else {
                    print("[Home] Device is recording, skipping file sync")
                    return
                }
                // Delay slightly to wait for blePenState completion
                // Silently fetch file list on reconnect; show banner and start download if new files found
                DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                    self?.syncManager.fetchFileList()
                }
            }
            .store(in: &cancellables)

        syncManager.statePublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] state in self?.updateSyncBanner(state) }
            .store(in: &cancellables)

        recordingManager.statePublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] state in
                self?.recordCard.configure(state: state)
            }
            .store(in: &cancellables)

        syncManager.filesPublisher
            .receive(on: DispatchQueue.main)
            .map { files in Array(files.filter { $0.isSynced }.prefix(5)) }
            .sink { [weak self] files in
                self?.recentFilesSection.configure(with: files)
            }
            .store(in: &cancellables)
    }

    private func setupAutoSync() {
        // Auto sync is handled in the connectedDevicePublisher subscription (triggered on device connect)
        // appDidBecomeActive no longer triggers sync to avoid starting when device is not connected
    }

    // MARK: - Banner Updates

    private func updateSyncBanner(_ state: SyncState) {
        switch state {
        case .syncing(let progress):
            syncBanner.configure(progress: progress, isWiFi: false)
            showBanner(syncBanner)
        case .wifiConnecting:
            // WiFi connecting state shown by FastTransferSheet, not banner
            break
        case .wifiTransferring(let progress):
            syncBanner.configure(progress: progress, isWiFi: true)
            showBanner(syncBanner)
        case .completed:
            hideBannerAfterDelay(syncBanner)
        default:
            syncBanner.isHidden = true
        }
    }

    private func updateRecordingBanner(_ state: RecordingState) {
        if state.isActive {
            recordingBanner.configure(state: state)
            showBanner(recordingBanner)
        } else {
            recordingBanner.isHidden = true
        }
    }

    private func showBanner(_ banner: UIView) {
        guard banner.isHidden else { return }
        banner.alpha = 0
        banner.isHidden = false
        UIView.animate(withDuration: 0.25) { banner.alpha = 1 }
    }

    private func hideBannerAfterDelay(_ banner: UIView) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            UIView.animate(withDuration: 0.25) { banner.alpha = 0 } completion: { _ in
                banner.isHidden = true
            }
        }
    }

    // MARK: - Actions

    @objc private func manageTapped() {
        guard let device = currentConnectedDevice else { return }
        let infoVC = DevicePanelViewController(device: device, deviceManager: deviceManager)
        navigationController?.pushViewController(infoVC, animated: true)
    }

    private func addDevice() {
        let scanVC = ScanningViewController()
        scanVC.isAddingDevice = true
        navigationController?.pushViewController(scanVC, animated: true)
    }

    @objc private func openRecording() {
        let nav = UINavigationController(rootViewController: RecordingViewController())
        nav.modalPresentationStyle = .fullScreen
        present(nav, animated: true)
    }

    private func openFile(_ file: RecordingFile) {
        let detailVC = FileDetailViewController(file: file, syncManager: SyncManager.shared)
        navigationController?.pushViewController(detailVC, animated: true)
    }

    private func showFastTransferDialog() {
        let sheet = FastTransferSheetViewController(syncManager: syncManager)
        present(sheet, animated: true)
    }
}

// MARK: - DeviceCardView (collapse/expand)

final class DeviceCardView: UIView, UIGestureRecognizerDelegate {

    var onExpandToggle: (() -> Void)?
    var onManageTapped: (() -> Void)?
    var onSwitchDevice: ((String) -> Void)?  // SN
    var onAddDevice: (() -> Void)?

    private var isExpanded = false
    private var pairedDevices: [PairedDeviceInfo] = []

    // Collapsed state views
    private let deviceIcon = UIImageView(image: UIImage(named: "icon_plaud_notepin"))
    private let nameLabel = UILabel()
    private let statusDot = UIView()
    private let statusLabel = UILabel()
    private let chevronIcon = UIImageView(image: UIImage(named: "icon_chevron_right"))

    // Expanded state views
    private let batteryTitleLabel = UILabel()
    private let batteryValueLabel = UILabel()
    private let batteryBar = UIView()
    private let batteryFill = UIView()
    private let storageTitleLabel = UILabel()
    private let storageValueLabel = UILabel()
    private let storageBar = UIView()
    private let storageFill = UIView()
    private let manageButton = UIButton(type: .system)

    // Other devices + Add device
    private let otherDevicesStack: UIStackView = {
        let s = UIStackView()
        s.axis = .vertical
        s.spacing = 0
        s.translatesAutoresizingMaskIntoConstraints = false
        return s
    }()

    // Expanded content container
    private let expandedContainer = UIView()
    private var heightConstraint: NSLayoutConstraint!

    override init(frame: CGRect) {
        super.init(frame: frame)
        setup()
    }
    required init?(coder: NSCoder) { fatalError() }

    private func setup() {
        backgroundColor = .white
        layer.cornerRadius = 12
        clipsToBounds = true

        // Collapsed row
        deviceIcon.contentMode = .scaleAspectFit
        deviceIcon.translatesAutoresizingMaskIntoConstraints = false

        nameLabel.font = .systemFont(ofSize: 14, weight: .regular)
        nameLabel.textColor = .black
        nameLabel.translatesAutoresizingMaskIntoConstraints = false

        statusDot.backgroundColor = UIColor(hex: "#6CAE85")
        statusDot.layer.cornerRadius = 3
        statusDot.translatesAutoresizingMaskIntoConstraints = false

        statusLabel.text = "Connected"
        statusLabel.font = .systemFont(ofSize: 13, weight: .regular)
        statusLabel.textColor = UIColor(hex: "#ADADAD")
        statusLabel.translatesAutoresizingMaskIntoConstraints = false

        chevronIcon.contentMode = .scaleAspectFit
        chevronIcon.tintColor = UIColor(hex: "#7A7A7A")
        chevronIcon.translatesAutoresizingMaskIntoConstraints = false

        [deviceIcon, nameLabel, statusDot, statusLabel, chevronIcon].forEach { addSubview($0) }

        // Expanded container
        expandedContainer.translatesAutoresizingMaskIntoConstraints = false
        expandedContainer.isHidden = true
        addSubview(expandedContainer)

        setupExpandedContent()

        heightConstraint = heightAnchor.constraint(equalToConstant: 70)
        heightConstraint.isActive = true

        NSLayoutConstraint.activate([
            deviceIcon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            deviceIcon.topAnchor.constraint(equalTo: topAnchor, constant: 19),
            deviceIcon.widthAnchor.constraint(equalToConstant: 32),
            deviceIcon.heightAnchor.constraint(equalToConstant: 32),

            nameLabel.leadingAnchor.constraint(equalTo: deviceIcon.trailingAnchor, constant: 12),
            nameLabel.topAnchor.constraint(equalTo: topAnchor, constant: 16),

            statusDot.leadingAnchor.constraint(equalTo: deviceIcon.trailingAnchor, constant: 12),
            statusDot.topAnchor.constraint(equalTo: nameLabel.bottomAnchor, constant: 4),
            statusDot.widthAnchor.constraint(equalToConstant: 6),
            statusDot.heightAnchor.constraint(equalToConstant: 6),

            statusLabel.leadingAnchor.constraint(equalTo: statusDot.trailingAnchor, constant: 4),
            statusLabel.centerYAnchor.constraint(equalTo: statusDot.centerYAnchor),

            chevronIcon.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
            chevronIcon.centerYAnchor.constraint(equalTo: topAnchor, constant: 35),
            chevronIcon.widthAnchor.constraint(equalToConstant: 16),
            chevronIcon.heightAnchor.constraint(equalToConstant: 16),

            expandedContainer.topAnchor.constraint(equalTo: topAnchor, constant: 70),
            expandedContainer.leadingAnchor.constraint(equalTo: leadingAnchor),
            expandedContainer.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])

        let tap = UITapGestureRecognizer(target: self, action: #selector(toggleExpand))
        tap.delegate = self
        addGestureRecognizer(tap)
    }

    private func setupExpandedContent() {
        // Battery
        batteryTitleLabel.text = "Battery"
        batteryTitleLabel.font = .systemFont(ofSize: 14)
        batteryTitleLabel.textColor = .black
        batteryTitleLabel.translatesAutoresizingMaskIntoConstraints = false

        batteryValueLabel.font = .systemFont(ofSize: 13)
        batteryValueLabel.textColor = UIColor(hex: "#ADADAD")
        batteryValueLabel.translatesAutoresizingMaskIntoConstraints = false

        batteryBar.backgroundColor = UIColor(hex: "#EBEBEB")
        batteryBar.layer.cornerRadius = 2
        batteryBar.translatesAutoresizingMaskIntoConstraints = false
        batteryFill.backgroundColor = UIColor(hex: "#6CAE85")
        batteryFill.layer.cornerRadius = 2
        batteryFill.translatesAutoresizingMaskIntoConstraints = false
        batteryBar.addSubview(batteryFill)

        // Storage
        storageTitleLabel.text = "Storage"
        storageTitleLabel.font = .systemFont(ofSize: 14)
        storageTitleLabel.textColor = .black
        storageTitleLabel.translatesAutoresizingMaskIntoConstraints = false

        storageValueLabel.font = .systemFont(ofSize: 13)
        storageValueLabel.textColor = UIColor(hex: "#ADADAD")
        storageValueLabel.translatesAutoresizingMaskIntoConstraints = false

        storageBar.backgroundColor = UIColor(hex: "#EBEBEB")
        storageBar.layer.cornerRadius = 2
        storageBar.translatesAutoresizingMaskIntoConstraints = false
        storageFill.backgroundColor = UIColor(hex: "#3D3D3D")
        storageFill.layer.cornerRadius = 2
        storageFill.translatesAutoresizingMaskIntoConstraints = false
        storageBar.addSubview(storageFill)

        // Manage button
        manageButton.setTitle("Manage device", for: .normal)
        manageButton.titleLabel?.font = .systemFont(ofSize: 14)
        manageButton.setTitleColor(.black, for: .normal)
        manageButton.layer.cornerRadius = 12
        manageButton.layer.borderWidth = 1
        manageButton.layer.borderColor = UIColor(hex: "#ADADAD").cgColor
        manageButton.translatesAutoresizingMaskIntoConstraints = false
        manageButton.addTarget(self, action: #selector(manageTapped), for: .touchUpInside)

        [batteryTitleLabel, batteryValueLabel, batteryBar,
         storageTitleLabel, storageValueLabel, storageBar,
         manageButton, otherDevicesStack].forEach { expandedContainer.addSubview($0) }

        NSLayoutConstraint.activate([
            batteryTitleLabel.topAnchor.constraint(equalTo: expandedContainer.topAnchor, constant: 20),
            batteryTitleLabel.leadingAnchor.constraint(equalTo: expandedContainer.leadingAnchor, constant: 16),
            batteryValueLabel.centerYAnchor.constraint(equalTo: batteryTitleLabel.centerYAnchor),
            batteryValueLabel.trailingAnchor.constraint(equalTo: expandedContainer.trailingAnchor, constant: -16),

            batteryBar.topAnchor.constraint(equalTo: batteryTitleLabel.bottomAnchor, constant: 8),
            batteryBar.leadingAnchor.constraint(equalTo: expandedContainer.leadingAnchor, constant: 16),
            batteryBar.trailingAnchor.constraint(equalTo: expandedContainer.trailingAnchor, constant: -16),
            batteryBar.heightAnchor.constraint(equalToConstant: 4),

            batteryFill.leadingAnchor.constraint(equalTo: batteryBar.leadingAnchor),
            batteryFill.topAnchor.constraint(equalTo: batteryBar.topAnchor),
            batteryFill.bottomAnchor.constraint(equalTo: batteryBar.bottomAnchor),

            storageTitleLabel.topAnchor.constraint(equalTo: batteryBar.bottomAnchor, constant: 20),
            storageTitleLabel.leadingAnchor.constraint(equalTo: expandedContainer.leadingAnchor, constant: 16),
            storageValueLabel.centerYAnchor.constraint(equalTo: storageTitleLabel.centerYAnchor),
            storageValueLabel.trailingAnchor.constraint(equalTo: expandedContainer.trailingAnchor, constant: -16),

            storageBar.topAnchor.constraint(equalTo: storageTitleLabel.bottomAnchor, constant: 8),
            storageBar.leadingAnchor.constraint(equalTo: expandedContainer.leadingAnchor, constant: 16),
            storageBar.trailingAnchor.constraint(equalTo: expandedContainer.trailingAnchor, constant: -16),
            storageBar.heightAnchor.constraint(equalToConstant: 4),

            storageFill.leadingAnchor.constraint(equalTo: storageBar.leadingAnchor),
            storageFill.topAnchor.constraint(equalTo: storageBar.topAnchor),
            storageFill.bottomAnchor.constraint(equalTo: storageBar.bottomAnchor),

            manageButton.topAnchor.constraint(equalTo: storageBar.bottomAnchor, constant: 20),
            manageButton.leadingAnchor.constraint(equalTo: expandedContainer.leadingAnchor, constant: 16),
            manageButton.heightAnchor.constraint(equalToConstant: 32),
            manageButton.widthAnchor.constraint(equalToConstant: 133),

            // Other devices list + Add device
            otherDevicesStack.topAnchor.constraint(equalTo: manageButton.bottomAnchor, constant: 16),
            otherDevicesStack.leadingAnchor.constraint(equalTo: expandedContainer.leadingAnchor),
            otherDevicesStack.trailingAnchor.constraint(equalTo: expandedContainer.trailingAnchor),
            otherDevicesStack.bottomAnchor.constraint(equalTo: expandedContainer.bottomAnchor, constant: -16),
        ])
    }

    // Battery/storage fill width constraints
    private var batteryFillWidth: NSLayoutConstraint?
    private var storageFillWidth: NSLayoutConstraint?
    private var cachedDevice: PlaudDevice?

    func configure(with device: PlaudDevice?) {
        cachedDevice = device
        guard let device = device else {
            nameLabel.text = "No Device"
            statusDot.backgroundColor = .systemGray
            statusLabel.text = "Disconnected"
            return
        }
        nameLabel.text = device.name
        statusDot.backgroundColor = UIColor(hex: "#6CAE85")
        statusLabel.text = "Connected"

        // Battery (color: >20% green, <=20% orange, <=10% red)
        let level = device.batteryLevel
        let chargingPrefix = device.isCharging ? "⚡ " : ""
        batteryValueLabel.text = "\(chargingPrefix)\(level)%"
        if level <= 10 {
            batteryFill.backgroundColor = UIColor(hex: "#FF503F")
        } else if level <= 20 {
            batteryFill.backgroundColor = .systemOrange
        } else {
            batteryFill.backgroundColor = UIColor(hex: "#6CAE85")
        }

        // Storage
        let usedGB = String(format: "%.1f", Double(device.storageUsed) / 1_073_741_824)
        let totalGB = String(format: "%.1f", Double(device.storageTotal) / 1_073_741_824)
        storageValueLabel.text = "\(usedGB) GB / \(totalGB) GB"

        updateBars()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        updateBars()
    }

    private func updateBars() {
        let barWidth = bounds.width - 32
        guard barWidth > 0 else { return }

        batteryFillWidth?.isActive = false
        let batteryRatio = CGFloat(cachedDevice?.batteryLevel ?? 0) / 100
        batteryFillWidth = batteryFill.widthAnchor.constraint(equalToConstant: barWidth * max(batteryRatio, 0.02))
        batteryFillWidth?.isActive = true

        storageFillWidth?.isActive = false
        let storageRatio = CGFloat(cachedDevice?.storageUsageRatio ?? 0)
        storageFillWidth = storageFill.widthAnchor.constraint(equalToConstant: barWidth * max(storageRatio, 0.02))
        storageFillWidth?.isActive = true
    }

    /// Configure paired device list (devices other than the currently active SN)
    func configurePairedDevices(_ devices: [PairedDeviceInfo], activeSN: String?) {
        pairedDevices = devices.filter { $0.serialNumber != activeSN }
        rebuildOtherDevicesStack()
    }

    private func rebuildOtherDevicesStack() {
        otherDevicesStack.arrangedSubviews.forEach { $0.removeFromSuperview() }

        // Separator + other devices
        if !pairedDevices.isEmpty {
            otherDevicesStack.addArrangedSubview(makeSeparator())
        }
        for device in pairedDevices {
            let row = makeDeviceRow(device)
            otherDevicesStack.addArrangedSubview(row)
            otherDevicesStack.addArrangedSubview(makeSeparator())
        }

        // "+ Add device" button
        let addBtn = UIButton(type: .system)
        let plusIcon = UIImage(systemName: "plus", withConfiguration: UIImage.SymbolConfiguration(pointSize: 14, weight: .medium))
        addBtn.setImage(plusIcon, for: .normal)
        addBtn.setTitle(" Add device", for: .normal)
        addBtn.titleLabel?.font = .systemFont(ofSize: 14)
        addBtn.tintColor = .black
        addBtn.setTitleColor(.black, for: .normal)
        addBtn.contentHorizontalAlignment = .leading
        addBtn.contentEdgeInsets = UIEdgeInsets(top: 12, left: 16, bottom: 12, right: 16)
        addBtn.addTarget(self, action: #selector(addDeviceTapped), for: .touchUpInside)
        otherDevicesStack.addArrangedSubview(addBtn)
    }

    private func makeDeviceRow(_ device: PairedDeviceInfo) -> UIView {
        let row = UIView()
        row.translatesAutoresizingMaskIntoConstraints = false

        let iconName = device.type == "notepro" ? "icon_plaud_notepin" : "icon_plaud_notepin" // Same icon for now, can differentiate by type later
        let icon = UIImageView(image: UIImage(named: iconName))
        icon.contentMode = .scaleAspectFit
        icon.translatesAutoresizingMaskIntoConstraints = false

        let label = UILabel()
        label.text = device.name
        label.font = .systemFont(ofSize: 14)
        label.textColor = .black
        label.translatesAutoresizingMaskIntoConstraints = false

        [icon, label].forEach { row.addSubview($0) }
        NSLayoutConstraint.activate([
            row.heightAnchor.constraint(equalToConstant: 48),
            icon.leadingAnchor.constraint(equalTo: row.leadingAnchor, constant: 16),
            icon.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 32),
            icon.heightAnchor.constraint(equalToConstant: 32),
            label.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 12),
            label.centerYAnchor.constraint(equalTo: row.centerYAnchor),
        ])

        let tap = UITapGestureRecognizer(target: self, action: #selector(otherDeviceTapped(_:)))
        row.addGestureRecognizer(tap)
        row.tag = device.serialNumber.hashValue
        row.accessibilityIdentifier = device.serialNumber
        return row
    }

    private func makeSeparator() -> UIView {
        let sep = UIView()
        sep.backgroundColor = UIColor(hex: "#EBEBEB")
        sep.translatesAutoresizingMaskIntoConstraints = false
        sep.heightAnchor.constraint(equalToConstant: 1).isActive = true
        return sep
    }

    @objc private func otherDeviceTapped(_ gesture: UITapGestureRecognizer) {
        guard let sn = gesture.view?.accessibilityIdentifier else {
            print("[DeviceCard] otherDeviceTapped but no accessibilityIdentifier")
            return
        }
        print("[DeviceCard] otherDeviceTapped sn=\(sn)")
        onSwitchDevice?(sn)
    }

    @objc private func addDeviceTapped() {
        print("[DeviceCard] addDeviceTapped")
        onAddDevice?()
    }

    // Only allow toggleExpand gesture in the top 70pt header area
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        let location = touch.location(in: self)
        return location.y <= 70
    }

    @objc private func toggleExpand() {
        isExpanded.toggle()
        expandedContainer.isHidden = !isExpanded
        // Dynamic height: base 226 + other device rows * 49 + add device button 44
        let extraHeight = CGFloat(pairedDevices.count) * 49 + 44 + (pairedDevices.isEmpty ? 0 : 1)
        heightConstraint.constant = isExpanded ? (226 + extraHeight) : 70

        // Rotate chevron
        UIView.animate(withDuration: 0.25) {
            self.chevronIcon.transform = self.isExpanded
                ? CGAffineTransform(rotationAngle: .pi / 2)
                : .identity
            self.superview?.layoutIfNeeded()
        }
        onExpandToggle?()
    }

    @objc private func manageTapped() {
        onManageTapped?()
    }
}

// MARK: - RecordingTriggerCardView (dark recording entry, idle / recording states)

final class RecordingTriggerCardView: UIView {

    var onTapped: (() -> Void)?
    private var recordingTimer: Timer?

    private let bgImageView: UIImageView = {
        let iv = UIImageView(image: UIImage(named: "record_card_bg"))
        iv.contentMode = .scaleAspectFill
        iv.clipsToBounds = true
        iv.translatesAutoresizingMaskIntoConstraints = false
        return iv
    }()

    private let micIcon: UIImageView = {
        let iv = UIImageView(image: UIImage(named: "icon_record_mic"))
        iv.contentMode = .scaleAspectFit
        iv.translatesAutoresizingMaskIntoConstraints = false
        return iv
    }()

    private let chevron: UIImageView = {
        let iv = UIImageView(image: UIImage(named: "icon_chevron_right"))
        iv.contentMode = .scaleAspectFit
        iv.tintColor = .white
        iv.translatesAutoresizingMaskIntoConstraints = false
        return iv
    }()

    private let titleLabel: UILabel = {
        let l = UILabel()
        l.text = "Capture important moments"
        l.font = .systemFont(ofSize: 20, weight: .light)
        l.textColor = .white
        l.translatesAutoresizingMaskIntoConstraints = false
        return l
    }()

    private let subtitleLabel: UILabel = {
        let l = UILabel()
        l.text = "Record via device microphone"
        l.font = .systemFont(ofSize: 13, weight: .regular)
        l.textColor = UIColor(hex: "#858585")
        l.translatesAutoresizingMaskIntoConstraints = false
        return l
    }()

    override init(frame: CGRect) {
        super.init(frame: frame)
        setup()
    }
    required init?(coder: NSCoder) { fatalError() }

    private func setup() {
        backgroundColor = .black
        layer.cornerRadius = 12
        clipsToBounds = true

        [bgImageView, micIcon, chevron, titleLabel, subtitleLabel].forEach { addSubview($0) }

        NSLayoutConstraint.activate([
            bgImageView.topAnchor.constraint(equalTo: topAnchor),
            bgImageView.bottomAnchor.constraint(equalTo: bottomAnchor),
            bgImageView.leadingAnchor.constraint(equalTo: leadingAnchor),
            bgImageView.trailingAnchor.constraint(equalTo: trailingAnchor),

            micIcon.topAnchor.constraint(equalTo: topAnchor, constant: 16),
            micIcon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            micIcon.widthAnchor.constraint(equalToConstant: 32),
            micIcon.heightAnchor.constraint(equalToConstant: 32),

            chevron.topAnchor.constraint(equalTo: topAnchor, constant: 21),
            chevron.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            chevron.widthAnchor.constraint(equalToConstant: 16),
            chevron.heightAnchor.constraint(equalToConstant: 16),

            subtitleLabel.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -16),
            subtitleLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),

            titleLabel.bottomAnchor.constraint(equalTo: subtitleLabel.topAnchor, constant: -4),
            titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
        ])

        addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(tapped)))
    }

    /// Update card state
    func configure(state: RecordingState) {
        recordingTimer?.invalidate()
        recordingTimer = nil

        switch state {
        case .recording(_, let startedAt):
            titleLabel.text = "Recording..."
            updateTimer(from: startedAt)
            recordingTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
                self?.updateTimer(from: startedAt)
            }
        default:
            titleLabel.text = "Capture important moments"
            subtitleLabel.text = "Record via device microphone"
        }
    }

    private func updateTimer(from startedAt: Date) {
        let elapsed = Int(Date().timeIntervalSince(startedAt))
        let h = elapsed / 3600
        let m = (elapsed % 3600) / 60
        let s = elapsed % 60
        subtitleLabel.text = String(format: "%02d:%02d:%02d", h, m, s)
    }

    @objc private func tapped() { onTapped?() }
}

// MARK: - SyncBannerView (dashed border sync card)

final class SyncBannerView: UIView {

    var onFastTransferTapped: (() -> Void)?

    private let syncIcon = UIImageView()
    private let titleLabel = UILabel()
    private let countLabel = UILabel()
    private let progressTrack = UIView()
    private let progressFill = UIView()
    private let speedLabel = UILabel()
    private let fastTransferPill = UIButton(type: .custom)
    private var progressFillWidth: NSLayoutConstraint?
    private let dashedBorder = CAShapeLayer()

    override init(frame: CGRect) {
        super.init(frame: frame)
        setup()
    }
    required init?(coder: NSCoder) { fatalError() }

    private func setup() {
        backgroundColor = .clear
        layer.cornerRadius = 12
        clipsToBounds = true

        // Dashed border
        dashedBorder.strokeColor = UIColor(hex: "#CCCCCC").cgColor
        dashedBorder.fillColor = UIColor.clear.cgColor
        dashedBorder.lineWidth = 1
        dashedBorder.lineDashPattern = [6, 4]
        layer.addSublayer(dashedBorder)

        // Sync icon
        syncIcon.image = UIImage(systemName: "arrow.triangle.2.circlepath")
        syncIcon.tintColor = UIColor(hex: "#3D3D3D")
        syncIcon.contentMode = .scaleAspectFit
        syncIcon.translatesAutoresizingMaskIntoConstraints = false

        // Title
        titleLabel.text = "Syncing recordings from device"
        titleLabel.font = .systemFont(ofSize: 14)
        titleLabel.textColor = UIColor(hex: "#3D3D3D")
        titleLabel.translatesAutoresizingMaskIntoConstraints = false

        // Progress count "2/4"
        countLabel.font = .systemFont(ofSize: 13)
        countLabel.textColor = UIColor(hex: "#7A7A7A")
        countLabel.translatesAutoresizingMaskIntoConstraints = false

        // Progress bar
        progressTrack.backgroundColor = UIColor(hex: "#D6D6D6").withAlphaComponent(0.5)
        progressTrack.layer.cornerRadius = 2
        progressTrack.translatesAutoresizingMaskIntoConstraints = false
        progressFill.backgroundColor = UIColor(hex: "#3D3D3D")
        progressFill.layer.cornerRadius = 2
        progressFill.translatesAutoresizingMaskIntoConstraints = false
        progressTrack.addSubview(progressFill)

        // Transfer speed
        speedLabel.font = .systemFont(ofSize: 13)
        speedLabel.textColor = UIColor(hex: "#7A7A7A")
        speedLabel.translatesAutoresizingMaskIntoConstraints = false

        // Fast Transfer button (black pill with white text)
        fastTransferPill.backgroundColor = .black
        fastTransferPill.layer.cornerRadius = 8
        fastTransferPill.setTitle(" Fast Transfer", for: .normal)
        fastTransferPill.setTitleColor(.white, for: .normal)
        fastTransferPill.titleLabel?.font = .systemFont(ofSize: 13)
        fastTransferPill.setImage(UIImage(systemName: "wifi", withConfiguration: UIImage.SymbolConfiguration(pointSize: 11))?.withTintColor(.white, renderingMode: .alwaysOriginal), for: .normal)
        fastTransferPill.contentEdgeInsets = UIEdgeInsets(top: 4, left: 8, bottom: 4, right: 8)
        fastTransferPill.translatesAutoresizingMaskIntoConstraints = false
        fastTransferPill.addTarget(self, action: #selector(ftTapped), for: .touchUpInside)

        [syncIcon, titleLabel, countLabel, progressTrack, speedLabel, fastTransferPill]
            .forEach { addSubview($0) }

        NSLayoutConstraint.activate([
            // Row 1: icon + title + count
            syncIcon.topAnchor.constraint(equalTo: topAnchor, constant: 16),
            syncIcon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            syncIcon.widthAnchor.constraint(equalToConstant: 14),
            syncIcon.heightAnchor.constraint(equalToConstant: 14),
            titleLabel.centerYAnchor.constraint(equalTo: syncIcon.centerYAnchor),
            titleLabel.leadingAnchor.constraint(equalTo: syncIcon.trailingAnchor, constant: 6),
            countLabel.centerYAnchor.constraint(equalTo: syncIcon.centerYAnchor),
            countLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),

            // Row 2: progress bar
            progressTrack.topAnchor.constraint(equalTo: syncIcon.bottomAnchor, constant: 12),
            progressTrack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            progressTrack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
            progressTrack.heightAnchor.constraint(equalToConstant: 4),
            progressFill.leadingAnchor.constraint(equalTo: progressTrack.leadingAnchor),
            progressFill.topAnchor.constraint(equalTo: progressTrack.topAnchor),
            progressFill.bottomAnchor.constraint(equalTo: progressTrack.bottomAnchor),

            // Row 3: speed + fast transfer
            speedLabel.topAnchor.constraint(equalTo: progressTrack.bottomAnchor, constant: 12),
            speedLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            speedLabel.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -12),
            fastTransferPill.centerYAnchor.constraint(equalTo: speedLabel.centerYAnchor),
            fastTransferPill.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
        ])
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        dashedBorder.path = UIBezierPath(roundedRect: bounds, cornerRadius: 12).cgPath
        dashedBorder.frame = bounds
    }

    func configure(progress: SyncProgress, isWiFi: Bool) {
        if progress.totalFiles > 0 {
            countLabel.text = "\(progress.syncedFiles)/\(progress.totalFiles)"
            let ratio = progress.progressFraction
            progressFillWidth?.isActive = false
            progressFillWidth = progressFill.widthAnchor.constraint(equalTo: progressTrack.widthAnchor, multiplier: CGFloat(max(ratio, 0.01)))
            progressFillWidth?.isActive = true
            speedLabel.text = progress.speedText.isEmpty ? (progress.currentFileName ?? "...") : progress.speedText
        } else {
            countLabel.text = ""
            progressFillWidth?.isActive = false
            progressFillWidth = progressFill.widthAnchor.constraint(equalToConstant: 0)
            progressFillWidth?.isActive = true
            speedLabel.text = "Retrieving file list..."
        }
        titleLabel.text = isWiFi ? "Fast Transfer" : "Syncing recordings from device"
        fastTransferPill.isHidden = isWiFi
    }

    @objc private func ftTapped() { onFastTransferTapped?() }
}

// MARK: - RecordingBannerView

final class RecordingBannerView: UIView {

    var onTapped: (() -> Void)?

    private let pulseView = UIView()
    private let titleLabel = UILabel()
    private let timerLabel = UILabel()
    private var pulseTimer: Timer?

    override init(frame: CGRect) {
        super.init(frame: frame)
        setup()
    }
    required init?(coder: NSCoder) { fatalError() }

    private func setup() {
        backgroundColor = .systemRed.withAlphaComponent(0.1)
        layer.cornerRadius = 12
        layer.borderWidth = 1
        layer.borderColor = UIColor.systemRed.withAlphaComponent(0.3).cgColor

        pulseView.backgroundColor = .systemRed
        pulseView.layer.cornerRadius = 6
        pulseView.translatesAutoresizingMaskIntoConstraints = false

        titleLabel.text = "Recording..."
        titleLabel.font = .systemFont(ofSize: 14, weight: .semibold)
        titleLabel.textColor = .systemRed
        titleLabel.translatesAutoresizingMaskIntoConstraints = false

        timerLabel.text = "00:00"
        timerLabel.font = .monospacedDigitSystemFont(ofSize: 14, weight: .regular)
        timerLabel.textColor = UIColor(hex: "#A3A3A3")
        timerLabel.translatesAutoresizingMaskIntoConstraints = false

        let chevron = UIImageView(image: UIImage(systemName: "chevron.right"))
        chevron.tintColor = UIColor(hex: "#A3A3A3")
        chevron.translatesAutoresizingMaskIntoConstraints = false

        [pulseView, titleLabel, timerLabel, chevron].forEach { addSubview($0) }

        NSLayoutConstraint.activate([
            pulseView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            pulseView.centerYAnchor.constraint(equalTo: centerYAnchor),
            pulseView.widthAnchor.constraint(equalToConstant: 12),
            pulseView.heightAnchor.constraint(equalToConstant: 12),
            titleLabel.leadingAnchor.constraint(equalTo: pulseView.trailingAnchor, constant: 8),
            titleLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            titleLabel.topAnchor.constraint(equalTo: topAnchor, constant: 14),
            titleLabel.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -14),
            timerLabel.leadingAnchor.constraint(equalTo: titleLabel.trailingAnchor, constant: 12),
            timerLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            chevron.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            chevron.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])

        addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(tapped)))
    }

    func configure(state: RecordingState) {
        let blink = CAKeyframeAnimation(keyPath: "opacity")
        blink.values = [1.0, 0.2, 1.0]
        blink.keyTimes = [0, 0.5, 1]
        blink.duration = 1.0
        blink.repeatCount = .infinity
        pulseView.layer.add(blink, forKey: "blink")
        if case .recording(_, let startedAt) = state { startTimer(from: startedAt) }
    }

    private func startTimer(from startedAt: Date) {
        pulseTimer?.invalidate()
        pulseTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            let elapsed = Int(Date().timeIntervalSince(startedAt))
            self?.timerLabel.text = String(format: "%02d:%02d", elapsed / 60, elapsed % 60)
        }
    }

    @objc private func tapped() { onTapped?() }
}

// MARK: - RecentFilesSectionView

final class RecentFilesSectionView: UIView {

    var onFileTapped: ((RecordingFile) -> Void)?

    private let headerLabel: UILabel = {
        let l = UILabel()
        l.text = "Recent files"
        l.font = .systemFont(ofSize: 24, weight: .light)
        l.textColor = UIColor(hex: "#3D3D3D")
        l.translatesAutoresizingMaskIntoConstraints = false
        return l
    }()

    private let stackView: UIStackView = {
        let s = UIStackView()
        s.axis = .vertical
        s.spacing = 8
        s.translatesAutoresizingMaskIntoConstraints = false
        return s
    }()

    private let emptyLabel: UILabel = {
        let l = UILabel()
        l.text = "No recordings yet"
        l.font = .systemFont(ofSize: 14)
        l.textColor = UIColor(hex: "#A3A3A3")
        l.textAlignment = .center
        l.translatesAutoresizingMaskIntoConstraints = false
        return l
    }()

    override init(frame: CGRect) {
        super.init(frame: frame)
        setup()
    }
    required init?(coder: NSCoder) { fatalError() }

    private func setup() {
        [headerLabel, stackView, emptyLabel].forEach { addSubview($0) }

        NSLayoutConstraint.activate([
            headerLabel.topAnchor.constraint(equalTo: topAnchor),
            headerLabel.leadingAnchor.constraint(equalTo: leadingAnchor),
            stackView.topAnchor.constraint(equalTo: headerLabel.bottomAnchor, constant: 20),
            stackView.leadingAnchor.constraint(equalTo: leadingAnchor),
            stackView.trailingAnchor.constraint(equalTo: trailingAnchor),
            stackView.bottomAnchor.constraint(equalTo: bottomAnchor),
            emptyLabel.topAnchor.constraint(equalTo: headerLabel.bottomAnchor, constant: 24),
            emptyLabel.centerXAnchor.constraint(equalTo: centerXAnchor),
            emptyLabel.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8),
        ])
    }

    func configure(with files: [RecordingFile]) {
        stackView.arrangedSubviews.forEach { $0.removeFromSuperview() }
        emptyLabel.isHidden = !files.isEmpty
        stackView.isHidden = files.isEmpty

        for file in files {
            let row = FileRowView(file: file)
            row.onTapped = { [weak self] in self?.onFileTapped?(file) }
            stackView.addArrangedSubview(row)
        }
    }
}

// MARK: - FileRowView

final class FileRowView: UIView {

    var onTapped: (() -> Void)?

    init(file: RecordingFile) {
        super.init(frame: .zero)
        setup(file: file)
        addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(tapped)))
    }
    required init?(coder: NSCoder) { fatalError() }

    private func setup(file: RecordingFile) {
        backgroundColor = .white
        layer.cornerRadius = 12
        translatesAutoresizingMaskIntoConstraints = false
        heightAnchor.constraint(equalToConstant: 72).isActive = true

        let nameLabel = UILabel()
        nameLabel.text = file.name
        nameLabel.font = .systemFont(ofSize: 14)
        nameLabel.textColor = UIColor(hex: "#3D3D3D")
        nameLabel.translatesAutoresizingMaskIntoConstraints = false

        let metaLabel = UILabel()
        metaLabel.text = formatMeta(file)
        metaLabel.font = .systemFont(ofSize: 13)
        metaLabel.textColor = UIColor(hex: "#A3A3A3")
        metaLabel.translatesAutoresizingMaskIntoConstraints = false

        [nameLabel, metaLabel].forEach { addSubview($0) }

        NSLayoutConstraint.activate([
            nameLabel.topAnchor.constraint(equalTo: topAnchor, constant: 16),
            nameLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            nameLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
            metaLabel.topAnchor.constraint(equalTo: nameLabel.bottomAnchor, constant: 4),
            metaLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
        ])
    }

    private func formatMeta(_ file: RecordingFile) -> String {
        let df = DateFormatter()
        df.dateFormat = "MMM d"
        let date = df.string(from: file.createdAt)

        let tf = DateFormatter()
        tf.dateFormat = "HH:mm"
        let time = tf.string(from: file.createdAt)

        let dur = formatDuration(file.duration)
        return "\(date)  ·  \(time)  ·  \(dur)"
    }

    private func formatDuration(_ seconds: TimeInterval) -> String {
        guard seconds > 0 else { return "--" }
        let total = Int(seconds)
        if total >= 3600 {
            return String(format: "%dh %dm", total / 3600, (total % 3600) / 60)
        }
        return String(format: "%dm %ds", total / 60, total % 60)
    }

    @objc private func tapped() { onTapped?() }
}
