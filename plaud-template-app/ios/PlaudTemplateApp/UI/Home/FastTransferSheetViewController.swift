import UIKit
import Combine

/// WiFi fast transfer confirmation dialog + connection state (matches Figma node 838:16493)
final class FastTransferSheetViewController: UIViewController {

    private let syncManager: SyncManagerProtocol
    private var cancellables = Set<AnyCancellable>()

    // MARK: - Confirmation State Views

    private let titleLabel: UILabel = {
        let l = UILabel()
        l.text = "Fast Transfer"
        l.font = .systemFont(ofSize: 24, weight: .light)
        l.textColor = .black
        l.translatesAutoresizingMaskIntoConstraints = false
        return l
    }()

    private let closeButton: UIButton = {
        let btn = UIButton(type: .system)
        btn.setImage(UIImage(systemName: "xmark", withConfiguration: UIImage.SymbolConfiguration(pointSize: 14, weight: .medium)), for: .normal)
        btn.tintColor = .black
        btn.translatesAutoresizingMaskIntoConstraints = false
        return btn
    }()

    private let bodyLabel: UILabel = {
        let l = UILabel()
        l.numberOfLines = 0
        l.translatesAutoresizingMaskIntoConstraints = false

        let text = "Increase transfer speed by up to 10x.\n\nYour phone will temporarily connect to the Plaud NotePin hotspot during transfer and reconnect to Wi-Fi afterward."
        let attr = NSMutableAttributedString(string: text, attributes: [
            .font: UIFont.systemFont(ofSize: 16),
            .foregroundColor: UIColor(hex: "#3D3D3D"),
        ])
        if let range = text.range(of: "10x") {
            attr.addAttribute(.font, value: UIFont.systemFont(ofSize: 16, weight: .semibold), range: NSRange(range, in: text))
        }
        l.attributedText = attr
        return l
    }()

    private let checkboxButton: UIButton = {
        let btn = UIButton(type: .custom)
        btn.setImage(UIImage(systemName: "circle", withConfiguration: UIImage.SymbolConfiguration(pointSize: 20)), for: .normal)
        btn.setImage(UIImage(systemName: "checkmark.circle.fill", withConfiguration: UIImage.SymbolConfiguration(pointSize: 20)), for: .selected)
        btn.tintColor = .black
        btn.translatesAutoresizingMaskIntoConstraints = false
        return btn
    }()

    private let checkboxLabel: UILabel = {
        let l = UILabel()
        l.text = "Never show again"
        l.font = .systemFont(ofSize: 14)
        l.textColor = UIColor(hex: "#3D3D3D")
        l.translatesAutoresizingMaskIntoConstraints = false
        return l
    }()

    private lazy var turnOnButton: UIButton = {
        let btn = UIButton(type: .custom)
        btn.setTitle("Turn on", for: .normal)
        btn.setTitleColor(.white, for: .normal)
        btn.titleLabel?.font = .systemFont(ofSize: 16, weight: .semibold)
        btn.backgroundColor = .black
        btn.layer.cornerRadius = 12
        btn.translatesAutoresizingMaskIntoConstraints = false
        btn.addTarget(self, action: #selector(turnOnTapped), for: .touchUpInside)
        return btn
    }()

    private lazy var cancelButton: UIButton = {
        let btn = UIButton(type: .custom)
        btn.setTitle("Cancel", for: .normal)
        btn.setTitleColor(.black, for: .normal)
        btn.titleLabel?.font = .systemFont(ofSize: 16)
        btn.backgroundColor = .white
        btn.layer.cornerRadius = 12
        btn.layer.borderWidth = 1
        btn.layer.borderColor = UIColor(hex: "#ADADAD").cgColor
        btn.translatesAutoresizingMaskIntoConstraints = false
        btn.addTarget(self, action: #selector(cancelTapped), for: .touchUpInside)
        return btn
    }()

    // MARK: - Connecting State Views

    private let connectingContainer: UIView = {
        let v = UIView()
        v.translatesAutoresizingMaskIntoConstraints = false
        v.isHidden = true
        return v
    }()

    private let spinner: UIActivityIndicatorView = {
        let s = UIActivityIndicatorView(style: .large)
        s.color = .black
        s.translatesAutoresizingMaskIntoConstraints = false
        return s
    }()

    private let connectStatusLabel: UILabel = {
        let l = UILabel()
        l.font = .systemFont(ofSize: 16)
        l.textColor = UIColor(hex: "#3D3D3D")
        l.textAlignment = .center
        l.numberOfLines = 2
        l.translatesAutoresizingMaskIntoConstraints = false
        return l
    }()

    // MARK: - Confirmation State Container

    private let confirmContainer = UIView()

    // MARK: - Init

    init(syncManager: SyncManagerProtocol) {
        self.syncManager = syncManager
        super.init(nibName: nil, bundle: nil)
        modalPresentationStyle = .pageSheet
    }
    required init?(coder: NSCoder) { fatalError() }

    // MARK: - Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .white
        if #available(iOS 16.0, *) {
            sheetPresentationController?.detents = [.custom { _ in 400 }]
            sheetPresentationController?.preferredCornerRadius = 12
        } else if #available(iOS 15.0, *) {
            sheetPresentationController?.detents = [.medium()]
            sheetPresentationController?.preferredCornerRadius = 12
        }
        setupLayout()
        setupBindings()
    }

    // MARK: - Layout

    private func setupLayout() {
        confirmContainer.translatesAutoresizingMaskIntoConstraints = false
        closeButton.addTarget(self, action: #selector(cancelTapped), for: .touchUpInside)
        checkboxButton.addTarget(self, action: #selector(checkboxTapped), for: .touchUpInside)

        // Confirmation state content
        [titleLabel, closeButton, bodyLabel, checkboxButton, checkboxLabel, turnOnButton, cancelButton]
            .forEach { confirmContainer.addSubview($0) }

        // Connecting state content
        [spinner, connectStatusLabel].forEach { connectingContainer.addSubview($0) }

        [confirmContainer, connectingContainer].forEach { view.addSubview($0) }

        NSLayoutConstraint.activate([
            // Confirmation container
            confirmContainer.topAnchor.constraint(equalTo: view.topAnchor),
            confirmContainer.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            confirmContainer.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            confirmContainer.bottomAnchor.constraint(equalTo: view.bottomAnchor),

            titleLabel.topAnchor.constraint(equalTo: confirmContainer.topAnchor, constant: 16),
            titleLabel.leadingAnchor.constraint(equalTo: confirmContainer.leadingAnchor, constant: 24),

            closeButton.centerYAnchor.constraint(equalTo: titleLabel.centerYAnchor),
            closeButton.trailingAnchor.constraint(equalTo: confirmContainer.trailingAnchor, constant: -16),
            closeButton.widthAnchor.constraint(equalToConstant: 32),
            closeButton.heightAnchor.constraint(equalToConstant: 32),

            bodyLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 16),
            bodyLabel.leadingAnchor.constraint(equalTo: confirmContainer.leadingAnchor, constant: 24),
            bodyLabel.trailingAnchor.constraint(equalTo: confirmContainer.trailingAnchor, constant: -24),

            checkboxButton.topAnchor.constraint(equalTo: bodyLabel.bottomAnchor, constant: 16),
            checkboxButton.leadingAnchor.constraint(equalTo: confirmContainer.leadingAnchor, constant: 24),
            checkboxButton.widthAnchor.constraint(equalToConstant: 24),
            checkboxButton.heightAnchor.constraint(equalToConstant: 24),

            checkboxLabel.centerYAnchor.constraint(equalTo: checkboxButton.centerYAnchor),
            checkboxLabel.leadingAnchor.constraint(equalTo: checkboxButton.trailingAnchor, constant: 8),

            turnOnButton.topAnchor.constraint(equalTo: checkboxButton.bottomAnchor, constant: 20),
            turnOnButton.leadingAnchor.constraint(equalTo: confirmContainer.leadingAnchor, constant: 24),
            turnOnButton.trailingAnchor.constraint(equalTo: confirmContainer.trailingAnchor, constant: -24),
            turnOnButton.heightAnchor.constraint(equalToConstant: 48),

            cancelButton.topAnchor.constraint(equalTo: turnOnButton.bottomAnchor, constant: 8),
            cancelButton.leadingAnchor.constraint(equalTo: confirmContainer.leadingAnchor, constant: 24),
            cancelButton.trailingAnchor.constraint(equalTo: confirmContainer.trailingAnchor, constant: -24),
            cancelButton.heightAnchor.constraint(equalToConstant: 48),

            // Connecting state container
            connectingContainer.topAnchor.constraint(equalTo: view.topAnchor),
            connectingContainer.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            connectingContainer.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            connectingContainer.bottomAnchor.constraint(equalTo: view.bottomAnchor),

            spinner.centerXAnchor.constraint(equalTo: connectingContainer.centerXAnchor),
            spinner.centerYAnchor.constraint(equalTo: connectingContainer.centerYAnchor, constant: -30),

            connectStatusLabel.topAnchor.constraint(equalTo: spinner.bottomAnchor, constant: 20),
            connectStatusLabel.leadingAnchor.constraint(equalTo: connectingContainer.leadingAnchor, constant: 24),
            connectStatusLabel.trailingAnchor.constraint(equalTo: connectingContainer.trailingAnchor, constant: -24),
        ])
    }

    // MARK: - State Observation

    private func setupBindings() {
        syncManager.statePublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] state in
                guard let self = self else { return }
                switch state {
                case .wifiConnecting(let phase):
                    self.showConnectingState(phase)
                case .wifiTransferring:
                    // Transfer started, dismiss dialog, banner takes over
                    self.dismiss(animated: true)
                case .failed(let msg) where msg.contains("WiFi") || msg.contains("handshake"):
                    self.showError(msg)
                default:
                    break
                }
            }
            .store(in: &cancellables)
    }

    private func showConnectingState(_ phase: WiFiConnectPhase) {
        confirmContainer.isHidden = true
        connectingContainer.isHidden = false
        spinner.startAnimating()

        switch phase {
        case .openingHotspot:
            connectStatusLabel.text = "Opening device hotspot..."
        case .connectingWiFi:
            connectStatusLabel.text = "Connecting to device WiFi...\nPlease tap \"Join\" when prompted"
        case .handshaking:
            connectStatusLabel.text = "Starting transfer..."
        }
    }

    private func showError(_ message: String) {
        spinner.stopAnimating()
        connectStatusLabel.text = "Connection failed:\n\(message)"

        // Dismiss after 3 seconds
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
            self?.dismiss(animated: true)
        }
    }

    // MARK: - Actions

    @objc private func turnOnTapped() {
        syncManager.startWiFiTransfer()
    }

    @objc private func cancelTapped() {
        dismiss(animated: true)
    }

    @objc private func checkboxTapped() {
        checkboxButton.isSelected.toggle()
        if checkboxButton.isSelected {
            UserDefaults.standard.set(true, forKey: "fastTransfer_neverShowAgain")
        } else {
            UserDefaults.standard.removeObject(forKey: "fastTransfer_neverShowAgain")
        }
    }
}
