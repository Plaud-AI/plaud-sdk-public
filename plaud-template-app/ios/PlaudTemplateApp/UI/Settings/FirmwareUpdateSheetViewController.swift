import UIKit
import Combine
import PlaudDeviceBasicSDK

/// Firmware update bottom sheet (Figma: 838:16171)
/// Shows progress percentage, segmented progress bar, status text and notes
final class FirmwareUpdateSheetViewController: UIViewController {

    // MARK: - Dependencies
    private let deviceManager: DeviceManagerProtocol
    private let deviceName: String
    private var cancellables = Set<AnyCancellable>()

    // MARK: - Callbacks
    var onComplete: ((Bool, String) -> Void)?

    // MARK: - Views

    /// Title "Firmware Update"
    private let titleLabel: UILabel = {
        let l = UILabel()
        l.text = "Firmware Update"
        l.font = .systemFont(ofSize: 24, weight: .light)
        l.textColor = .black
        l.translatesAutoresizingMaskIntoConstraints = false
        return l
    }()

    /// Large percentage number "45%"
    private let percentLabel: UILabel = {
        let l = UILabel()
        l.text = "0%"
        l.font = .systemFont(ofSize: 44, weight: .light)
        l.textColor = .black
        l.translatesAutoresizingMaskIntoConstraints = false
        return l
    }()

    /// Status text "Downloading Firmware..."
    private let statusLabel: UILabel = {
        let l = UILabel()
        l.text = "Preparing..."
        l.font = .systemFont(ofSize: 14)
        l.textColor = PlaudTheme.gray5
        l.textAlignment = .right
        l.translatesAutoresizingMaskIntoConstraints = false
        return l
    }()

    /// Segmented progress bar container
    private let progressContainer: UIView = {
        let v = UIView()
        v.translatesAutoresizingMaskIntoConstraints = false
        return v
    }()

    /// Description text
    private let descriptionLabel: UILabel = {
        let l = UILabel()
        l.font = .systemFont(ofSize: 14)
        l.textColor = PlaudTheme.gray5
        l.numberOfLines = 0
        l.translatesAutoresizingMaskIntoConstraints = false
        return l
    }()

    /// Notes
    private let notesLabel: UILabel = {
        let l = UILabel()
        l.font = .systemFont(ofSize: 14)
        l.textColor = PlaudTheme.gray5
        l.numberOfLines = 0
        l.translatesAutoresizingMaskIntoConstraints = false
        return l
    }()

    // Segmented progress bar related
    private let totalSegments = 30
    private var segmentViews: [UIView] = []

    // MARK: - Init

    init(deviceManager: DeviceManagerProtocol, deviceName: String) {
        self.deviceManager = deviceManager
        self.deviceName = deviceName
        super.init(nibName: nil, bundle: nil)
        modalPresentationStyle = .pageSheet
        isModalInPresentation = true // Prevent swipe-to-dismiss
    }

    required init?(coder: NSCoder) { fatalError() }

    // MARK: - Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .white
        setupLayout()
        startUpdate()
    }

    // MARK: - Layout

    private func setupLayout() {
        descriptionLabel.text = "\(deviceName) is updating. This may take a few minutes. The device will restart automatically when the update is complete."

        let noteText = """
        Note:
        •  Keep device charging.
        •  Keep the app open.
        •  Keep device close to your phone.
        """
        notesLabel.text = noteText

        [titleLabel, percentLabel, statusLabel, progressContainer, descriptionLabel, notesLabel]
            .forEach { view.addSubview($0) }

        setupSegmentedProgress()

        NSLayoutConstraint.activate([
            // Title
            titleLabel.topAnchor.constraint(equalTo: view.topAnchor, constant: 16),
            titleLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 24),

            // Percentage (left) + status text (right)
            percentLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 24),
            percentLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 24),

            statusLabel.bottomAnchor.constraint(equalTo: percentLabel.bottomAnchor, constant: -5),
            statusLabel.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -24),

            // Segmented progress bar
            progressContainer.topAnchor.constraint(equalTo: percentLabel.bottomAnchor, constant: 12),
            progressContainer.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 24),
            progressContainer.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -24),
            progressContainer.heightAnchor.constraint(equalToConstant: 16),

            // Description text
            descriptionLabel.topAnchor.constraint(equalTo: progressContainer.bottomAnchor, constant: 40),
            descriptionLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 24),
            descriptionLabel.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -24),

            // Notes
            notesLabel.topAnchor.constraint(equalTo: descriptionLabel.bottomAnchor, constant: 16),
            notesLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 24),
            notesLabel.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -24),
        ])
    }

    /// Create segmented progress bar (30 vertical bars)
    private func setupSegmentedProgress() {
        let stack = UIStackView()
        stack.axis = .horizontal
        stack.distribution = .fillEqually
        stack.spacing = 2
        stack.translatesAutoresizingMaskIntoConstraints = false
        progressContainer.addSubview(stack)

        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: progressContainer.topAnchor),
            stack.bottomAnchor.constraint(equalTo: progressContainer.bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: progressContainer.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: progressContainer.trailingAnchor),
        ])

        for _ in 0..<totalSegments {
            let seg = UIView()
            seg.backgroundColor = UIColor(hex: "#E5E5E5")
            seg.layer.cornerRadius = 1.5
            stack.addArrangedSubview(seg)
            segmentViews.append(seg)
        }
    }

    /// Update segmented progress bar
    private func updateProgress(_ progress: Float) {
        let pct = Int(progress * 100)
        percentLabel.text = "\(pct)%"

        let filledCount = Int(Float(totalSegments) * progress)
        for (i, seg) in segmentViews.enumerated() {
            seg.backgroundColor = i < filledCount ? .black : UIColor(hex: "#E5E5E5")
        }
    }

    // MARK: - OTA

    private var otaSuccess = false
    private var otaVersion = ""
    private var otaError: String?

    private func startUpdate() {
        deviceManager.startFirmwareUpdate(
            progress: { [weak self] phase, pct in
                #if DEBUG
                print("[FirmwareSheet] progress: phase=\(phase.rawValue), pct=\(Int(pct * 100))%")
                #endif
                DispatchQueue.main.async {
                    self?.updateProgress(pct)
                    switch phase {
                    case .downloading:
                        self?.statusLabel.text = "Downloading Firmware..."
                    case .installing:
                        self?.statusLabel.text = "Installing on device... \(Int(pct * 100))%"
                    case .restarting:
                        self?.statusLabel.text = "Restarting device..."
                        self?.updateProgress(1.0)
                        self?.descriptionLabel.text = "Device is restarting with the new firmware. Please wait..."
                    case .complete:
                        self?.statusLabel.text = "Update complete!"
                        self?.updateProgress(1.0)
                    @unknown default:
                        break
                    }
                }
            },
            completion: { [weak self] result in
                #if DEBUG
                print("[FirmwareSheet] OTA complete: success=\(result.success), version=\(result.version), error=\(result.errorMessage ?? "nil")")
                #endif
                DispatchQueue.main.async {
                    if result.success {
                        self?.otaSuccess = true
                        self?.otaVersion = result.version
                        self?.statusLabel.text = "Update complete!"
                        self?.updateProgress(1.0)
                        self?.descriptionLabel.text = "Firmware updated successfully. Reconnecting..."
                        // Wait for device reconnection then dismiss
                        self?.waitForReconnect()
                    } else {
                        self?.otaError = result.errorMessage
                        self?.statusLabel.text = "Update failed"
                        self?.descriptionLabel.text = result.errorMessage ?? "Update failed. Please try again."
                        // Wait for reconnection on failure before dismissing
                        self?.waitForReconnect()
                    }
                }
            }
        )
    }

    /// Wait for device disconnect -> restart -> reconnect, then dismiss sheet
    /// SDK completion fires before device actually disconnects, need to wait for real reconnection
    private func waitForReconnect() {
        descriptionLabel.text = "Device is restarting with the new firmware. Please wait..."
        statusLabel.text = "Restarting device..."

        // dropFirst() skips current state (device hasn't disconnected yet, currently .connected)
        // Wait for: .connected(current) -> .disconnected(device restarting) -> .connected(reconnected)
        deviceManager.connectionStatePublisher
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] state in
                guard let self = self else { return }
                switch state {
                case .connected:
                    // Device reconnected successfully
                    self.cancellables.removeAll()
                    self.statusLabel.text = self.otaSuccess ? "Update complete!" : "Device reconnected"
                    self.descriptionLabel.text = self.otaSuccess
                        ? "Firmware updated successfully."
                        : "Device reconnected."
                    self.dismissAfterDelay()
                case .disconnected:
                    self.statusLabel.text = "Restarting device..."
                case .scanning:
                    self.statusLabel.text = "Searching for device..."
                default:
                    break
                }
            }
            .store(in: &cancellables)

        // Timeout after 60 seconds (device restart + reconnection may be slow)
        DispatchQueue.main.asyncAfter(deadline: .now() + 60) { [weak self] in
            guard let self = self, self.presentingViewController != nil else { return }
            self.cancellables.removeAll()
            self.dismissAfterDelay()
        }
    }

    private func dismissAfterDelay() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            self?.isModalInPresentation = false
            self?.dismiss(animated: true) {
                if self?.otaSuccess == true {
                    self?.onComplete?(true, self?.otaVersion ?? "")
                } else {
                    self?.onComplete?(false, self?.otaError ?? "Update failed")
                }
            }
        }
    }
}
