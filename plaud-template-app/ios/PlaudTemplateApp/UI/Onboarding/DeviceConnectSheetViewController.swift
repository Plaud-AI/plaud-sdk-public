import UIKit
import Combine

/// Onboarding Screen 3/4/6/7 — Connect Device Bottom Sheet
///
/// Panel height 378px, white background, top corner radius 12px
final class DeviceConnectSheetViewController: UIViewController {

    // MARK: - Dependencies
    private var devices: [ScannedDevice] = []
    private let deviceManager: DeviceManagerProtocol
    private var cancellables = Set<AnyCancellable>()
    var onDismiss: (() -> Void)?

    // MARK: - State
    private var currentIndex: Int = 0

    // MARK: - Views

    /// Title "Connect Device"
    private let titleLabel: UILabel = {
        let l = UILabel()
        l.text = "Connect Device"
        l.font = PlaudTheme.title2()
        l.textColor = PlaudTheme.labelPrimary
        l.translatesAutoresizingMaskIntoConstraints = false
        return l
    }()

    /// Close button X
    private let closeButton: UIButton = {
        let btn = UIButton(type: .system)
        btn.setImage(UIImage(systemName: "xmark", withConfiguration: UIImage.SymbolConfiguration(pointSize: 14, weight: .medium)), for: .normal)
        btn.tintColor = PlaudTheme.labelPrimary
        btn.translatesAutoresizingMaskIntoConstraints = false
        return btn
    }()

    /// Device icon
    private let deviceIconView: UIImageView = {
        let iv = UIImageView(image: UIImage(named: "icon_notepin"))
        iv.contentMode = .scaleAspectFit
        iv.translatesAutoresizingMaskIntoConstraints = false
        return iv
    }()

    /// Device name
    private let deviceNameLabel: UILabel = {
        let l = UILabel()
        l.font = PlaudTheme.headline()
        l.textColor = PlaudTheme.labelPrimary
        l.textAlignment = .center
        l.translatesAutoresizingMaskIntoConstraints = false
        return l
    }()

    /// Serial number
    private let snLabel: UILabel = {
        let l = UILabel()
        l.font = PlaudTheme.footnote()
        l.textColor = PlaudTheme.gray5
        l.textAlignment = .center
        l.translatesAutoresizingMaskIntoConstraints = false
        return l
    }()

    /// Page indicator (shown when multiple devices)
    private let pageDotsView = PageDotsView()

    /// Connecting state row (spinner + "Connecting...", hidden by default)
    private let connectingRow: UIView = {
        let v = UIView()
        v.isHidden = true
        v.translatesAutoresizingMaskIntoConstraints = false
        return v
    }()
    private let activityIndicator = UIActivityIndicatorView(style: .medium)
    private let connectingLabel: UILabel = {
        let l = UILabel()
        l.text = "Connecting..."
        l.font = PlaudTheme.body()
        l.textColor = PlaudTheme.labelQuaternary
        l.translatesAutoresizingMaskIntoConstraints = false
        return l
    }()

    /// Connect button
    private lazy var connectButton: UIButton = {
        let btn = PlaudTheme.makePrimaryButton(title: "Connect")
        btn.addTarget(self, action: #selector(connectTapped), for: .touchUpInside)
        return btn
    }()

    // MARK: - Constraint references (adjusted during connecting state)
    private var snToConnectingConstraint: NSLayoutConstraint?
    private var snToDotsConstraint: NSLayoutConstraint?
    private var dotsToConnectingConstraint: NSLayoutConstraint?

    init(deviceManager: DeviceManagerProtocol) {
        self.deviceManager = deviceManager
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError() }

    // MARK: - Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .white
        setupLayout()
        setupConnectingRow()
        setupGestures()
        setupBindings()
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        onDismiss?()
    }

    // MARK: - Layout

    private func setupLayout() {
        closeButton.addTarget(self, action: #selector(closeTapped), for: .touchUpInside)

        pageDotsView.translatesAutoresizingMaskIntoConstraints = false
        pageDotsView.isHidden = true

        [titleLabel, closeButton, deviceIconView, deviceNameLabel, snLabel,
         pageDotsView, connectingRow, connectButton].forEach { view.addSubview($0) }

        NSLayoutConstraint.activate([
            // Title
            titleLabel.topAnchor.constraint(equalTo: view.topAnchor, constant: 24),
            titleLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 24),

            // Close button
            closeButton.topAnchor.constraint(equalTo: view.topAnchor, constant: 16),
            closeButton.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
            closeButton.widthAnchor.constraint(equalToConstant: 32),
            closeButton.heightAnchor.constraint(equalToConstant: 32),

            // Device icon
            deviceIconView.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 28),
            deviceIconView.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            deviceIconView.widthAnchor.constraint(equalToConstant: 88),
            deviceIconView.heightAnchor.constraint(equalToConstant: 88),

            // Device name
            deviceNameLabel.topAnchor.constraint(equalTo: deviceIconView.bottomAnchor, constant: 12),
            deviceNameLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 24),
            deviceNameLabel.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -24),

            // SN
            snLabel.topAnchor.constraint(equalTo: deviceNameLabel.bottomAnchor, constant: 4),
            snLabel.centerXAnchor.constraint(equalTo: view.centerXAnchor),

            // Page dots (multi-device)
            pageDotsView.topAnchor.constraint(equalTo: snLabel.bottomAnchor, constant: 16),
            pageDotsView.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            pageDotsView.heightAnchor.constraint(equalToConstant: 4),

            // Connecting row
            connectingRow.topAnchor.constraint(equalTo: snLabel.bottomAnchor, constant: 16),
            connectingRow.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            connectingRow.heightAnchor.constraint(equalToConstant: 24),

            // Connect button
            connectButton.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -20),
            connectButton.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 24),
            connectButton.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -24),
            connectButton.heightAnchor.constraint(equalToConstant: 48),
        ])
    }

    private func setupConnectingRow() {
        activityIndicator.translatesAutoresizingMaskIntoConstraints = false
        [activityIndicator, connectingLabel].forEach { connectingRow.addSubview($0) }
        NSLayoutConstraint.activate([
            activityIndicator.leadingAnchor.constraint(equalTo: connectingRow.leadingAnchor),
            activityIndicator.centerYAnchor.constraint(equalTo: connectingRow.centerYAnchor),
            activityIndicator.widthAnchor.constraint(equalToConstant: 24),
            activityIndicator.heightAnchor.constraint(equalToConstant: 24),
            connectingLabel.leadingAnchor.constraint(equalTo: activityIndicator.trailingAnchor, constant: 8),
            connectingLabel.centerYAnchor.constraint(equalTo: connectingRow.centerYAnchor),
            connectingLabel.trailingAnchor.constraint(equalTo: connectingRow.trailingAnchor),
        ])
    }

    // MARK: - Gestures (swipe left/right to switch between devices)

    private func setupGestures() {
        let swipeLeft = UISwipeGestureRecognizer(target: self, action: #selector(swipedLeft))
        swipeLeft.direction = .left
        let swipeRight = UISwipeGestureRecognizer(target: self, action: #selector(swipedRight))
        swipeRight.direction = .right
        view.addGestureRecognizer(swipeLeft)
        view.addGestureRecognizer(swipeRight)
    }

    // MARK: - Data Bindings

    private func configure(with device: ScannedDevice) {
        deviceNameLabel.text = device.name
        snLabel.text = "SN: \(device.serialNumber)"
        pageDotsView.configure(total: devices.count, current: currentIndex)
    }

    private func setupBindings() {
        // Continuously listen for scan results, new devices join list in real-time
        deviceManager.scannedDevicesPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] newDevices in
                guard let self = self, !newDevices.isEmpty else { return }
                // Merge new devices (deduplicate, preserve existing order)
                var merged = self.devices
                for device in newDevices {
                    if !merged.contains(where: { $0.serialNumber == device.serialNumber }) {
                        merged.append(device)
                    }
                }
                guard merged.count != self.devices.count || self.devices.isEmpty else { return }
                self.devices = merged
                self.updateDeviceDisplay()
            }
            .store(in: &cancellables)

        deviceManager.connectionStatePublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] state in
                if case .connecting = state {
                    self?.showConnectingState()
                }
            }
            .store(in: &cancellables)
    }

    /// Update UI when device list changes
    private func updateDeviceDisplay() {
        guard !devices.isEmpty else { return }
        if currentIndex >= devices.count { currentIndex = devices.count - 1 }
        configure(with: devices[currentIndex])
        pageDotsView.isHidden = devices.count <= 1
        pageDotsView.configure(total: devices.count, current: currentIndex)
    }

    private func showConnectingState() {
        connectButton.isHidden = true
        titleLabel.isHidden = true
        connectingRow.isHidden = false
        pageDotsView.isHidden = true
        activityIndicator.startAnimating()
    }

    // MARK: - Actions

    @objc private func closeTapped() {
        dismiss(animated: true)
    }

    @objc private func connectTapped() {
        guard let userId = RecordingStore.shared.userId else { return }
        let device = devices[currentIndex]
        deviceManager.connect(device, userId: userId)
    }

    @objc private func swipedLeft() {
        guard currentIndex < devices.count - 1 else { return }
        currentIndex += 1
        configure(with: devices[currentIndex])
    }

    @objc private func swipedRight() {
        guard currentIndex > 0 else { return }
        currentIndex -= 1
        configure(with: devices[currentIndex])
    }
}

// MARK: - PageDotsView

final class PageDotsView: UIView {

    private var dotViews: [UIView] = []

    override init(frame: CGRect) {
        super.init(frame: frame)
        translatesAutoresizingMaskIntoConstraints = false
    }

    required init?(coder: NSCoder) { fatalError() }

    func configure(total: Int, current: Int) {
        dotViews.forEach { $0.removeFromSuperview() }
        dotViews.removeAll()
        guard total > 1 else { return }

        let stack = UIStackView()
        stack.axis = .horizontal
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])

        for i in 0..<total {
            let dot = UIView()
            dot.layer.cornerRadius = 2
            dot.translatesAutoresizingMaskIntoConstraints = false
            stack.addArrangedSubview(dot)
            let isActive = i == current
            NSLayoutConstraint.activate([
                dot.widthAnchor.constraint(equalToConstant: isActive ? 24 : 12),
                dot.heightAnchor.constraint(equalToConstant: 4),
            ])
            dot.backgroundColor = isActive ? .black : UIColor(hex: "#d6d6d6")
            dotViews.append(dot)
        }
    }
}
