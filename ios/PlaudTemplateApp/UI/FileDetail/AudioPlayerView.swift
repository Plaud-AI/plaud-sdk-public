import UIKit
import AVFoundation

/// Bottom floating audio player (Figma style: frosted glass + time + progress bar + controls)
final class AudioPlayerView: UIView, AVAudioPlayerDelegate {

    private var player: AVAudioPlayer?
    private var displayLink: CADisplayLink?

    deinit {
        displayLink?.invalidate()
        player?.stop()
    }

    // Time
    private let currentTimeLabel: UILabel = {
        let l = UILabel()
        l.font = .systemFont(ofSize: 13)
        l.textColor = .black
        l.text = "00:00:00"
        l.translatesAutoresizingMaskIntoConstraints = false
        return l
    }()

    private let totalTimeLabel: UILabel = {
        let l = UILabel()
        l.font = .systemFont(ofSize: 13)
        l.textColor = UIColor(hex: "#A3A3A3")
        l.text = "00:00:00"
        l.translatesAutoresizingMaskIntoConstraints = false
        return l
    }()

    // Progress bar
    private let progressSlider: UISlider = {
        let s = UISlider()
        s.minimumTrackTintColor = UIColor(hex: "#3D3D3D")
        s.maximumTrackTintColor = UIColor(hex: "#EBEBEB")
        s.setThumbImage(UIImage(), for: .normal)
        s.translatesAutoresizingMaskIntoConstraints = false
        return s
    }()

    // Figma icons
    private let rewindButton: UIButton = {
        let btn = UIButton(type: .system)
        btn.setImage(UIImage(named: "icon_rewind5")?.withRenderingMode(.alwaysTemplate), for: .normal)
        btn.tintColor = UIColor(hex: "#3D3D3D")
        btn.translatesAutoresizingMaskIntoConstraints = false
        return btn
    }()

    private let playPauseButton: UIButton = {
        let btn = UIButton(type: .custom)
        btn.setImage(UIImage(named: "icon_play")?.withRenderingMode(.alwaysTemplate), for: .normal)
        btn.tintColor = .white
        btn.backgroundColor = UIColor(hex: "#3D3D3D")
        btn.layer.cornerRadius = 20
        btn.translatesAutoresizingMaskIntoConstraints = false
        return btn
    }()

    private let forwardButton: UIButton = {
        let btn = UIButton(type: .system)
        btn.setImage(UIImage(named: "icon_forward5")?.withRenderingMode(.alwaysTemplate), for: .normal)
        btn.tintColor = UIColor(hex: "#3D3D3D")
        btn.translatesAutoresizingMaskIntoConstraints = false
        return btn
    }()

    private var isPaused = true

    override init(frame: CGRect) {
        super.init(frame: frame)
        setup()
    }
    required init?(coder: NSCoder) { fatalError() }

    private func setup() {
        backgroundColor = UIColor.white.withAlphaComponent(0.7)
        layer.cornerRadius = 12
        layer.borderWidth = 1
        layer.borderColor = UIColor(hex: "#EBEBEB").cgColor
        layer.shadowColor = UIColor.black.cgColor
        layer.shadowOpacity = 0.1
        layer.shadowOffset = CGSize(width: 0, height: 2)
        layer.shadowRadius = 24

        let blur = UIVisualEffectView(effect: UIBlurEffect(style: .light))
        blur.translatesAutoresizingMaskIntoConstraints = false
        blur.layer.cornerRadius = 12
        blur.clipsToBounds = true
        insertSubview(blur, at: 0)

        let controlStack = UIStackView(arrangedSubviews: [rewindButton, playPauseButton, forwardButton])
        controlStack.axis = .horizontal
        controlStack.spacing = 24
        controlStack.alignment = .center
        controlStack.translatesAutoresizingMaskIntoConstraints = false

        [currentTimeLabel, totalTimeLabel, progressSlider, controlStack].forEach { addSubview($0) }

        rewindButton.addTarget(self, action: #selector(rewindTapped), for: .touchUpInside)
        playPauseButton.addTarget(self, action: #selector(playPauseTapped), for: .touchUpInside)
        forwardButton.addTarget(self, action: #selector(forwardTapped), for: .touchUpInside)
        progressSlider.addTarget(self, action: #selector(sliderChanged), for: .valueChanged)

        NSLayoutConstraint.activate([
            blur.topAnchor.constraint(equalTo: topAnchor),
            blur.bottomAnchor.constraint(equalTo: bottomAnchor),
            blur.leadingAnchor.constraint(equalTo: leadingAnchor),
            blur.trailingAnchor.constraint(equalTo: trailingAnchor),

            currentTimeLabel.topAnchor.constraint(equalTo: topAnchor, constant: 12),
            currentTimeLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            totalTimeLabel.topAnchor.constraint(equalTo: topAnchor, constant: 12),
            totalTimeLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),

            progressSlider.topAnchor.constraint(equalTo: currentTimeLabel.bottomAnchor, constant: 12),
            progressSlider.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            progressSlider.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),

            controlStack.topAnchor.constraint(equalTo: progressSlider.bottomAnchor, constant: 16),
            controlStack.centerXAnchor.constraint(equalTo: centerXAnchor),
            controlStack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -12),

            playPauseButton.widthAnchor.constraint(equalToConstant: 56),
            playPauseButton.heightAnchor.constraint(equalToConstant: 40),
            rewindButton.widthAnchor.constraint(equalToConstant: 32),
            rewindButton.heightAnchor.constraint(equalToConstant: 32),
            forwardButton.widthAnchor.constraint(equalToConstant: 32),
            forwardButton.heightAnchor.constraint(equalToConstant: 32),
        ])
    }

    // MARK: - Configuration

    /// Configure with a playable audio path (wav/mp3) and duration
    func configure(audioPath: String, duration: TimeInterval) {
        totalTimeLabel.text = formatTime(duration)
        guard FileManager.default.fileExists(atPath: audioPath) else {
            print("[AudioPlayer] File not found: \(audioPath)")
            return
        }
        let url = URL(fileURLWithPath: audioPath)
        loadPlayer(url: url)
    }

    private func loadPlayer(url: URL) {
        do {
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .default)
            try AVAudioSession.sharedInstance().setActive(true)
            player = try AVAudioPlayer(contentsOf: url)
            player?.delegate = self
            player?.prepareToPlay()
            if let d = player?.duration, d > 0 {
                totalTimeLabel.text = formatTime(d)
            }
            print("[AudioPlayer] Load success: duration=\(player?.duration ?? 0)")
        } catch {
            print("[AudioPlayer] Load failed: \(error.localizedDescription)")
        }
    }

    // MARK: - AVAudioPlayerDelegate

    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        isPaused = true
        stopUpdating()
        updatePlayPauseIcon()
        currentTimeLabel.text = formatTime(0)
        progressSlider.value = 0
        player.currentTime = 0
    }

    // MARK: - Actions

    @objc private func playPauseTapped() {
        guard let player = player else { return }
        if player.isPlaying {
            player.pause()
            stopUpdating()
            isPaused = true
            updatePlayPauseIcon()
        } else {
            player.play()
            startUpdating()
            isPaused = false
            updatePlayPauseIcon()
        }
    }

    @objc private func rewindTapped() {
        guard let player = player else { return }
        player.currentTime = max(0, player.currentTime - 5)
        updateTimeDisplay()
    }

    @objc private func forwardTapped() {
        guard let player = player else { return }
        player.currentTime = min(player.duration, player.currentTime + 5)
        updateTimeDisplay()
    }

    @objc private func sliderChanged() {
        guard let player = player else { return }
        player.currentTime = Double(progressSlider.value) * player.duration
        updateTimeDisplay()
    }

    private func updatePlayPauseIcon() {
        if isPaused {
            playPauseButton.setImage(UIImage(named: "icon_play")?.withRenderingMode(.alwaysTemplate), for: .normal)
        } else {
            // Pause uses SF Symbol (Figma has no separate pause asset)
            playPauseButton.setImage(UIImage(systemName: "pause.fill", withConfiguration: UIImage.SymbolConfiguration(pointSize: 16)), for: .normal)
        }
    }

    // MARK: - Timer Updates

    private func startUpdating() {
        displayLink = CADisplayLink(target: self, selector: #selector(updateTimeDisplay))
        if #available(iOS 15.0, *) {
            displayLink?.preferredFrameRateRange = CAFrameRateRange(minimum: 5, maximum: 15)
        } else {
            displayLink?.preferredFramesPerSecond = 10
        }
        displayLink?.add(to: .main, forMode: .common)
    }

    private func stopUpdating() {
        displayLink?.invalidate()
        displayLink = nil
    }

    @objc private func updateTimeDisplay() {
        guard let player = player else { return }
        currentTimeLabel.text = formatTime(player.currentTime)
        progressSlider.value = player.duration > 0 ? Float(player.currentTime / player.duration) : 0
    }

    private func formatTime(_ seconds: TimeInterval) -> String {
        let total = Int(max(0, seconds))
        return String(format: "%02d:%02d:%02d", total / 3600, (total % 3600) / 60, total % 60)
    }
}
