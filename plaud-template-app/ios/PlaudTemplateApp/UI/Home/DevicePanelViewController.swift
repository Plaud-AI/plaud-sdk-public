import UIKit
import Combine

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
    }

    // MARK: - Navigation Bar

    private func setupNavBar() {
        navigationController?.setNavigationBarHidden(false, animated: true)
        navigationItem.title = device.name
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

        [infoCard, actionsCard].forEach { contentView.addSubview($0) }

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

            actionsCard.topAnchor.constraint(equalTo: infoCard.bottomAnchor, constant: 24),
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
        nameValueLabel.text = device.name
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
            }
            .store(in: &cancellables)

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
        let name = device.name
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
        let alert = UIAlertController(title: "Unpair Device", message: "You'll need to pair again to use it.", preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "Unpair", style: .destructive) { [weak self] _ in
            self?.deviceManager.unpair()
            let nav = UINavigationController(rootViewController: WelcomeViewController())
            self?.view.window?.rootViewController = nav
        })
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        present(alert, animated: true)
    }
}
