import UIKit
import Combine

/// Recording page: dark full-screen modal, idle -> recording states
final class RecordingViewController: UIViewController {

    // MARK: - SDK Integration
    private let recordingManager: RecordingManagerProtocol = RecordingManager.shared
    private var cancellables = Set<AnyCancellable>()

    // MARK: - Views

    /// Top-right close button
    private let closeButton: UIButton = {
        let btn = UIButton(type: .system)
        btn.setImage(UIImage(systemName: "xmark", withConfiguration: UIImage.SymbolConfiguration(pointSize: 16, weight: .medium)), for: .normal)
        btn.tintColor = .white
        btn.translatesAutoresizingMaskIntoConstraints = false
        return btn
    }()

    /// Title ("Start Recording" / "Recording")
    private let titleLabel: UILabel = {
        let l = UILabel()
        l.text = "Start Recording"
        l.font = .systemFont(ofSize: 24, weight: .light)
        l.textColor = .white
        l.textAlignment = .center
        l.translatesAutoresizingMaskIntoConstraints = false
        return l
    }()

    /// Subtitle / timer
    private let subtitleLabel: UILabel = {
        let l = UILabel()
        l.text = "Record via device microphone"
        l.font = .systemFont(ofSize: 13, weight: .regular)
        l.textColor = UIColor(hex: "#858585")
        l.textAlignment = .center
        l.translatesAutoresizingMaskIntoConstraints = false
        return l
    }()

    /// Waveform view (shown during recording)
    private let waveformView = WaveformView()

    /// Record / stop button
    private let recordButton = UIView()
    private let stopIcon = UIView()

    // MARK: - State
    private var timerDisplayTimer: Timer?
    private var currentState: RecordingState = .idle
    private var recordButtonSize: NSLayoutConstraint!

    // MARK: - Lifecycle

    /// Background image
    private let bgImageView: UIImageView = {
        let iv = UIImageView(image: UIImage(named: "recording_bg"))
        iv.contentMode = .scaleAspectFill
        iv.translatesAutoresizingMaskIntoConstraints = false
        return iv
    }()

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = UIColor(hex: "#1B1B1B")
        navigationController?.setNavigationBarHidden(true, animated: false)
        setupLayout()
        setupBindings()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        timerDisplayTimer?.invalidate()
    }

    // MARK: - Layout

    private func setupLayout() {
        closeButton.addTarget(self, action: #selector(closeTapped), for: .touchUpInside)

        // Waveform
        waveformView.translatesAutoresizingMaskIntoConstraints = false
        waveformView.isHidden = true

        // Record button (white circle)
        recordButton.backgroundColor = .white
        recordButton.layer.cornerRadius = 36
        recordButton.translatesAutoresizingMaskIntoConstraints = false
        recordButton.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(recordTapped)))

        // Stop icon (black rounded square, shown during recording)
        stopIcon.backgroundColor = .black
        stopIcon.layer.cornerRadius = 4
        stopIcon.isHidden = true
        stopIcon.translatesAutoresizingMaskIntoConstraints = false
        recordButton.addSubview(stopIcon)

        view.addSubview(bgImageView)
        [closeButton, titleLabel, subtitleLabel, waveformView, recordButton]
            .forEach { view.addSubview($0) }

        recordButtonSize = recordButton.widthAnchor.constraint(equalToConstant: 72)

        NSLayoutConstraint.activate([
            // Background image
            bgImageView.topAnchor.constraint(equalTo: view.topAnchor),
            bgImageView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            bgImageView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            bgImageView.trailingAnchor.constraint(equalTo: view.trailingAnchor),

            // Close button: top-right
            closeButton.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 10),
            closeButton.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -24),
            closeButton.widthAnchor.constraint(equalToConstant: 24),
            closeButton.heightAnchor.constraint(equalToConstant: 24),

            // Title: vertically center-upper
            titleLabel.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            titleLabel.topAnchor.constraint(equalTo: view.topAnchor, constant: 494),

            // Subtitle / timer
            subtitleLabel.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            subtitleLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 16),

            // Waveform
            waveformView.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            waveformView.topAnchor.constraint(equalTo: view.topAnchor, constant: 638),
            waveformView.widthAnchor.constraint(equalToConstant: 392),
            waveformView.heightAnchor.constraint(equalToConstant: 28),

            // Record button
            recordButton.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            recordButton.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -48),
            recordButtonSize,
            recordButton.heightAnchor.constraint(equalTo: recordButton.widthAnchor),

            // Stop icon (centered)
            stopIcon.centerXAnchor.constraint(equalTo: recordButton.centerXAnchor),
            stopIcon.centerYAnchor.constraint(equalTo: recordButton.centerYAnchor),
            stopIcon.widthAnchor.constraint(equalToConstant: 20),
            stopIcon.heightAnchor.constraint(equalToConstant: 20),
        ])
    }

    // MARK: - SDK Bindings

    private func setupBindings() {
        recordingManager.statePublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] state in self?.updateUI(for: state) }
            .store(in: &cancellables)

        recordingManager.waveformLevelPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] level in self?.waveformView.push(level: level) }
            .store(in: &cancellables)
    }

    // MARK: - UI Updates

    private func updateUI(for state: RecordingState) {
        currentState = state
        switch state {
        case .idle:
            titleLabel.text = "Start Recording"
            subtitleLabel.text = "Record via device microphone"
            subtitleLabel.font = .systemFont(ofSize: 13, weight: .regular)
            waveformView.isHidden = true
            waveformView.reset()
            stopIcon.isHidden = true
            recordButtonSize.constant = 72
            recordButton.layer.cornerRadius = 36
            timerDisplayTimer?.invalidate()

        case .recording(_, let startedAt):
            titleLabel.text = "Recording"
            subtitleLabel.font = .systemFont(ofSize: 14, weight: .regular)
            waveformView.isHidden = false
            stopIcon.isHidden = false
            recordButtonSize.constant = 64
            recordButton.layer.cornerRadius = 32
            startTimerDisplay(from: startedAt)

        case .paused(let sessionId):
            titleLabel.text = "Paused"
            stopIcon.isHidden = false
            timerDisplayTimer?.invalidate()
        }

        UIView.animate(withDuration: 0.2) { self.view.layoutIfNeeded() }
    }

    private func startTimerDisplay(from startedAt: Date) {
        timerDisplayTimer?.invalidate()
        timerDisplayTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            let elapsed = Int(Date().timeIntervalSince(startedAt))
            let h = elapsed / 3600
            let m = (elapsed % 3600) / 60
            let s = elapsed % 60
            self?.subtitleLabel.text = String(format: "%02d:%02d:%02d", h, m, s)
        }
    }

    // MARK: - Actions

    @objc private func closeTapped() {
        dismiss(animated: true)
    }

    @objc private func recordTapped() {
        switch currentState {
        case .idle:
            recordingManager.startRecord()
        case .recording:
            recordingManager.stopRecord()
            dismiss(animated: true)
        case .paused:
            recordingManager.resumeRecord()
        }
    }
}

// MARK: - WaveformView (white vertical bar waveform, center-aligned)

final class WaveformView: UIView {

    private var levels: [Float] = Array(repeating: 0, count: 80)
    private let barWidth: CGFloat = 2
    private let barSpacing: CGFloat = 2.5

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
    }
    required init?(coder: NSCoder) { fatalError() }

    func push(level: Float) {
        levels.removeFirst()
        levels.append(level)
        setNeedsDisplay()
    }

    func reset() {
        levels = Array(repeating: 0, count: 80)
        setNeedsDisplay()
    }

    override func draw(_ rect: CGRect) {
        guard let ctx = UIGraphicsGetCurrentContext() else { return }
        let midY = rect.midY
        let maxBarHeight = rect.height
        let totalWidth = CGFloat(levels.count) * (barWidth + barSpacing) - barSpacing
        let startX = (rect.width - totalWidth) / 2

        for (i, level) in levels.enumerated() {
            let x = startX + CGFloat(i) * (barWidth + barSpacing)
            let barHeight = max(2, CGFloat(level) * maxBarHeight)
            let barRect = CGRect(x: x, y: midY - barHeight / 2, width: barWidth, height: barHeight)

            let alpha = CGFloat(0.4 + Double(level) * 0.6)
            UIColor.white.withAlphaComponent(alpha).setFill()
            let path = UIBezierPath(roundedRect: barRect, cornerRadius: barWidth / 2)
            ctx.addPath(path.cgPath)
            ctx.fillPath()
        }
    }
}
