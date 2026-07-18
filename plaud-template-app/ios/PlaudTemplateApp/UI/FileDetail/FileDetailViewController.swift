import UIKit
import Combine
import PlaudBleSDK

/// File detail page: Title + Metadata + Tab(Summary/Transcript) + action menu
final class FileDetailViewController: UIViewController {

    // MARK: - Dependencies
    private var file: RecordingFile
    private let syncManager: SyncManagerProtocol
    private let transcriptionManager = TranscriptionManager.shared
    private var cancellables = Set<AnyCancellable>()

    // MARK: - Views
    private let scrollView = UIScrollView()
    private let contentView = UIView()

    /// Recording title
    private let titleLabel: UILabel = {
        let l = UILabel()
        l.font = .systemFont(ofSize: 28, weight: .light)
        l.textColor = .black
        l.numberOfLines = 2
        l.translatesAutoresizingMaskIntoConstraints = false
        return l
    }()

    /// Metadata row
    private let metaLabel: UILabel = {
        let l = UILabel()
        l.font = .systemFont(ofSize: 13)
        l.textColor = UIColor(hex: "#A3A3A3")
        l.translatesAutoresizingMaskIntoConstraints = false
        return l
    }()

    /// Tab bar
    private let summaryTab = UIButton(type: .system)
    private let transcriptTab = UIButton(type: .system)
    private let tabIndicator = UIView()
    private var tabIndicatorLeading: NSLayoutConstraint!

    /// Content area
    private let contentContainer = UIView()

    /// Summary content
    private let summaryContentLabel: UILabel = {
        let l = UILabel()
        l.font = .systemFont(ofSize: 14)
        l.textColor = UIColor(hex: "#757575")
        l.numberOfLines = 0
        l.translatesAutoresizingMaskIntoConstraints = false
        l.isHidden = true
        return l
    }()

    /// Transcript content (structured list: speaker + timestamp + text)
    private let transcriptStack: UIStackView = {
        let s = UIStackView()
        s.axis = .vertical
        s.spacing = 24
        s.translatesAutoresizingMaskIntoConstraints = false
        s.isHidden = true
        return s
    }()

    /// Stores structured transcription results
    private var transcriptResults: [TranscriptionResult] = []

    /// Bottom floating audio player
    private let audioPlayerView = AudioPlayerView()

    /// Empty state view
    private let emptyStateView = UIView()
    private let emptyIcon = UIImageView()
    private let emptyTitle = UILabel()
    private let emptySubtitle = UILabel()
    private let generateButton = UIButton(type: .custom)

    /// Progress view
    private let progressLabel: UILabel = {
        let l = UILabel()
        l.font = .systemFont(ofSize: 16)
        l.textColor = .black
        l.textAlignment = .center
        l.translatesAutoresizingMaskIntoConstraints = false
        l.isHidden = true
        return l
    }()
    private let progressSubLabel: UILabel = {
        let l = UILabel()
        l.font = .systemFont(ofSize: 13)
        l.textColor = UIColor(hex: "#A3A3A3")
        l.textAlignment = .center
        l.translatesAutoresizingMaskIntoConstraints = false
        l.isHidden = true
        return l
    }()

    private var selectedTab = 1 // Summary not yet integrated, default to Transcript

    init(file: RecordingFile, syncManager: SyncManagerProtocol) {
        self.file = file
        self.syncManager = syncManager
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError() }

    // MARK: - Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = PlaudTheme.backgroundPrimary
        setupNavBar()
        setupLayout()
        loadContent()
        setupTranscriptionBinding()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        navigationController?.setNavigationBarHidden(false, animated: animated)
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        if isMovingFromParent {
            navigationController?.setNavigationBarHidden(true, animated: animated)
        }
    }

    // MARK: - Navigation Bar

    private func setupNavBar() {
        let backBtn = UIButton(type: .system)
        backBtn.setImage(UIImage(systemName: "chevron.left", withConfiguration: UIImage.SymbolConfiguration(pointSize: 17, weight: .medium)), for: .normal)
        backBtn.tintColor = .black
        backBtn.addTarget(self, action: #selector(backTapped), for: .touchUpInside)
        navigationItem.leftBarButtonItem = UIBarButtonItem(customView: backBtn)

        let moreBtn = UIButton(type: .system)
        moreBtn.setImage(UIImage(systemName: "ellipsis", withConfiguration: UIImage.SymbolConfiguration(pointSize: 17, weight: .medium)), for: .normal)
        moreBtn.tintColor = .black
        moreBtn.addTarget(self, action: #selector(showMoreActions), for: .touchUpInside)
        navigationItem.rightBarButtonItem = UIBarButtonItem(customView: moreBtn)
    }

    // MARK: - Layout

    private func setupLayout() {
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.alwaysBounceVertical = true
        scrollView.showsVerticalScrollIndicator = false
        view.addSubview(scrollView)

        contentView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.addSubview(contentView)

        setupTabBar()
        setupEmptyState()

        // Summary not yet integrated, hide tab bar, only show Transcript
        summaryTab.isHidden = true
        tabIndicator.isHidden = true

        [titleLabel, metaLabel, summaryTab, transcriptTab, tabIndicator,
         contentContainer].forEach { contentView.addSubview($0) }

        [summaryContentLabel, transcriptStack, emptyStateView,
         progressLabel, progressSubLabel].forEach { contentContainer.addSubview($0) }

        // Floating player
        audioPlayerView.translatesAutoresizingMaskIntoConstraints = false
        audioPlayerView.isHidden = true
        view.addSubview(audioPlayerView)

        contentContainer.translatesAutoresizingMaskIntoConstraints = false

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

            // Title
            titleLabel.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 16),
            titleLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 24),
            titleLabel.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -24),

            // Metadata
            metaLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 12),
            metaLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 24),
            metaLabel.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -24),

            // Tab bar
            summaryTab.topAnchor.constraint(equalTo: metaLabel.bottomAnchor, constant: 16),
            summaryTab.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 24),
            summaryTab.heightAnchor.constraint(equalToConstant: 40),

            transcriptTab.topAnchor.constraint(equalTo: metaLabel.bottomAnchor, constant: 16),
            transcriptTab.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 24),
            transcriptTab.heightAnchor.constraint(equalToConstant: 40),

            // Tab indicator
            tabIndicator.bottomAnchor.constraint(equalTo: summaryTab.bottomAnchor),
            tabIndicator.heightAnchor.constraint(equalToConstant: 2),
            tabIndicator.widthAnchor.constraint(equalTo: summaryTab.widthAnchor),

            // Content container
            contentContainer.topAnchor.constraint(equalTo: transcriptTab.bottomAnchor, constant: 24),
            contentContainer.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 24),
            contentContainer.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -24),
            contentContainer.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -120),
            // Ensure contentContainer has enough height for buttons to be tappable
            contentContainer.heightAnchor.constraint(greaterThanOrEqualToConstant: 400),

            // Content labels
            summaryContentLabel.topAnchor.constraint(equalTo: contentContainer.topAnchor),
            summaryContentLabel.leadingAnchor.constraint(equalTo: contentContainer.leadingAnchor),
            summaryContentLabel.trailingAnchor.constraint(equalTo: contentContainer.trailingAnchor),
            summaryContentLabel.bottomAnchor.constraint(lessThanOrEqualTo: contentContainer.bottomAnchor),

            transcriptStack.topAnchor.constraint(equalTo: contentContainer.topAnchor),
            transcriptStack.leadingAnchor.constraint(equalTo: contentContainer.leadingAnchor),
            transcriptStack.trailingAnchor.constraint(equalTo: contentContainer.trailingAnchor),
            transcriptStack.bottomAnchor.constraint(lessThanOrEqualTo: contentContainer.bottomAnchor),

            // Floating player
            audioPlayerView.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 24),
            audioPlayerView.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -24),
            audioPlayerView.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -80),

            // Empty state
            emptyStateView.centerXAnchor.constraint(equalTo: contentContainer.centerXAnchor),
            emptyStateView.topAnchor.constraint(equalTo: contentContainer.topAnchor, constant: 80),
            emptyStateView.leadingAnchor.constraint(equalTo: contentContainer.leadingAnchor),
            emptyStateView.trailingAnchor.constraint(equalTo: contentContainer.trailingAnchor),

            // Progress
            progressLabel.centerXAnchor.constraint(equalTo: contentContainer.centerXAnchor),
            progressLabel.topAnchor.constraint(equalTo: contentContainer.topAnchor, constant: 100),
            progressSubLabel.centerXAnchor.constraint(equalTo: contentContainer.centerXAnchor),
            progressSubLabel.topAnchor.constraint(equalTo: progressLabel.bottomAnchor, constant: 8),
        ])

        tabIndicatorLeading = tabIndicator.leadingAnchor.constraint(equalTo: summaryTab.leadingAnchor)
        tabIndicatorLeading.isActive = true
    }

    private func setupTabBar() {
        summaryTab.setTitle("Summary", for: .normal)
        summaryTab.titleLabel?.font = .systemFont(ofSize: 14, weight: .medium)
        summaryTab.setTitleColor(.black, for: .normal)
        summaryTab.translatesAutoresizingMaskIntoConstraints = false
        summaryTab.addTarget(self, action: #selector(summaryTabTapped), for: .touchUpInside)

        transcriptTab.setTitle("Transcript", for: .normal)
        transcriptTab.titleLabel?.font = .systemFont(ofSize: 14)
        transcriptTab.setTitleColor(UIColor(hex: "#757575"), for: .normal)
        transcriptTab.translatesAutoresizingMaskIntoConstraints = false
        transcriptTab.addTarget(self, action: #selector(transcriptTabTapped), for: .touchUpInside)

        tabIndicator.backgroundColor = .black
        tabIndicator.translatesAutoresizingMaskIntoConstraints = false
    }

    private func setupEmptyState() {
        emptyStateView.translatesAutoresizingMaskIntoConstraints = false

        emptyIcon.image = UIImage(systemName: "sparkles")
        emptyIcon.tintColor = UIColor(hex: "#757575")
        emptyIcon.contentMode = .scaleAspectFit
        emptyIcon.translatesAutoresizingMaskIntoConstraints = false

        emptyTitle.text = "Generate recording insights"
        emptyTitle.font = .systemFont(ofSize: 16)
        emptyTitle.textColor = UIColor(hex: "#757575")
        emptyTitle.textAlignment = .center
        emptyTitle.translatesAutoresizingMaskIntoConstraints = false

        emptySubtitle.text = "Transcript and summary will be generated"
        emptySubtitle.font = .systemFont(ofSize: 13)
        emptySubtitle.textColor = UIColor(hex: "#A3A3A3")
        emptySubtitle.textAlignment = .center
        emptySubtitle.translatesAutoresizingMaskIntoConstraints = false

        generateButton.setTitle("Generate", for: .normal)
        generateButton.setTitleColor(.white, for: .normal)
        generateButton.titleLabel?.font = .systemFont(ofSize: 16, weight: .semibold)
        generateButton.backgroundColor = .black
        generateButton.layer.cornerRadius = 12
        generateButton.translatesAutoresizingMaskIntoConstraints = false
        generateButton.addTarget(self, action: #selector(generateTapped), for: .touchUpInside)

        [emptyIcon, emptyTitle, emptySubtitle, generateButton].forEach { emptyStateView.addSubview($0) }

        NSLayoutConstraint.activate([
            emptyIcon.topAnchor.constraint(equalTo: emptyStateView.topAnchor),
            emptyIcon.centerXAnchor.constraint(equalTo: emptyStateView.centerXAnchor),
            emptyIcon.widthAnchor.constraint(equalToConstant: 40),
            emptyIcon.heightAnchor.constraint(equalToConstant: 40),

            emptyTitle.topAnchor.constraint(equalTo: emptyIcon.bottomAnchor, constant: 16),
            emptyTitle.centerXAnchor.constraint(equalTo: emptyStateView.centerXAnchor),

            emptySubtitle.topAnchor.constraint(equalTo: emptyTitle.bottomAnchor, constant: 8),
            emptySubtitle.centerXAnchor.constraint(equalTo: emptyStateView.centerXAnchor),

            generateButton.topAnchor.constraint(equalTo: emptySubtitle.bottomAnchor, constant: 24),
            generateButton.centerXAnchor.constraint(equalTo: emptyStateView.centerXAnchor),
            generateButton.widthAnchor.constraint(equalToConstant: 354),
            generateButton.heightAnchor.constraint(equalToConstant: 48),
            generateButton.bottomAnchor.constraint(equalTo: emptyStateView.bottomAnchor),
        ])
    }

    // MARK: - Content Loading

    private func loadContent() {
        titleLabel.text = file.name
        metaLabel.text = formatMeta()

        // 从缓存恢复转写结果
        if transcriptResults.isEmpty,
           let json = file.transcriptJSON,
           let data = json.data(using: .utf8),
           let cached = try? JSONDecoder().decode([TranscriptionResult].self, from: data),
           !cached.isEmpty {
            transcriptResults = cached
            prepareAudioPlayer()
        }

        updateTabContent()
    }

    private func formatMeta() -> String {
        let df = DateFormatter()
        df.dateFormat = "MMM d, yyyy"
        let date = df.string(from: file.createdAt)

        let tf = DateFormatter()
        tf.dateFormat = "HH:mm"
        let time = tf.string(from: file.createdAt)

        let dur = formatDuration(file.duration)
        return "\(date)  ·  \(time)  ·  \(dur)"
    }

    private func formatDuration(_ s: TimeInterval) -> String {
        guard s > 0 else { return "--" }
        let t = Int(s)
        if t >= 3600 { return String(format: "%dh %dm", t / 3600, (t % 3600) / 60) }
        return String(format: "%dm %ds", t / 60, t % 60)
    }

    // MARK: - Tab Switching

    @objc private func summaryTabTapped() {
        selectedTab = 0
        updateTabAppearance()
        updateTabContent()
    }

    @objc private func transcriptTabTapped() {
        selectedTab = 1
        updateTabAppearance()
        updateTabContent()
    }

    private func updateTabAppearance() {
        let isSummary = selectedTab == 0
        summaryTab.titleLabel?.font = .systemFont(ofSize: 14, weight: isSummary ? .medium : .regular)
        summaryTab.setTitleColor(isSummary ? .black : UIColor(hex: "#757575"), for: .normal)
        transcriptTab.titleLabel?.font = .systemFont(ofSize: 14, weight: isSummary ? .regular : .medium)
        transcriptTab.setTitleColor(isSummary ? UIColor(hex: "#757575") : .black, for: .normal)

        tabIndicatorLeading.isActive = false
        tabIndicatorLeading = tabIndicator.leadingAnchor.constraint(equalTo: isSummary ? summaryTab.leadingAnchor : transcriptTab.leadingAnchor)
        tabIndicatorLeading.isActive = true

        // Dynamic width
        tabIndicator.constraints.filter { $0.firstAttribute == .width }.forEach { $0.isActive = false }
        tabIndicator.widthAnchor.constraint(equalTo: isSummary ? summaryTab.widthAnchor : transcriptTab.widthAnchor).isActive = true

        UIView.animate(withDuration: 0.2) { self.view.layoutIfNeeded() }
    }

    private func updateTabContent() {
        if selectedTab == 0 {
            // Summary tab
            transcriptStack.isHidden = true
            if let summary = file.summaryText, !summary.isEmpty {
                summaryContentLabel.text = summary
                summaryContentLabel.isHidden = false
                emptyStateView.isHidden = true
                progressLabel.isHidden = true
                progressSubLabel.isHidden = true
            } else {
                summaryContentLabel.isHidden = true
                emptyStateView.isHidden = false
                emptyIcon.image = UIImage(systemName: "sparkles")
                emptyTitle.text = "Generate recording insights"
                emptySubtitle.text = "Transcript and summary will be generated"
                generateButton.isHidden = false
                progressLabel.isHidden = true
                progressSubLabel.isHidden = true
            }
        } else {
            // Transcript tab
            summaryContentLabel.isHidden = true
            if !transcriptResults.isEmpty {
                showTranscriptResults(transcriptResults)
                transcriptStack.isHidden = false
                emptyStateView.isHidden = true
                // audioPlayerView 的显隐由 prepareAudioPlayer() 在转码完成后控制
                progressLabel.isHidden = true
                progressSubLabel.isHidden = true
            } else {
                transcriptStack.isHidden = true
                emptyStateView.isHidden = false
                emptyIcon.image = UIImage(systemName: "text.alignleft")
                emptyTitle.text = "No transcript available"
                emptySubtitle.text = "Generate to get transcript"
                generateButton.isHidden = false
                audioPlayerView.isHidden = true
                progressLabel.isHidden = true
                progressSubLabel.isHidden = true
            }
        }
    }

    // MARK: - Transcription

    @objc private func generateTapped() {
        print("[FileDetail] generateTapped: isSynced=\(file.isSynced), localPath=\(file.localPath ?? "nil")")
        startTranscription()
    }

    private func startTranscription() {
        guard file.isSynced else {
            print("[FileDetail] File not synced")
            let alert = UIAlertController(
                title: "File Not Synced",
                message: "This recording needs to be synced first.",
                preferredStyle: .alert
            )
            alert.addAction(UIAlertAction(title: "Sync Now", style: .default) { [weak self] _ in
                self?.syncAndTranscribe()
            })
            alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
            present(alert, animated: true)
            return
        }

        guard let path = RecordingStore.shared.resolveAbsolutePath(for: file) else {
            print("[FileDetail] resolveAbsolutePath returned nil, localPath=\(file.localPath ?? "nil")")
            let alert = UIAlertController(title: "File Not Found", message: "Audio file not found.", preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: "OK", style: .default))
            present(alert, animated: true)
            return
        }
        print("[FileDetail] Starting transcription: \(path)")

        transcriptionManager.reset()
        transcriptionManager.transcribe(audioPath: path)
    }

    private func syncAndTranscribe() {
        showProgress("Syncing from device...", sub: nil)
        syncManager.startSync()

        syncManager.statePublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] state in
                guard let self = self else { return }
                switch state {
                case .completed:
                    if let updated = RecordingStore.shared.allFiles.first(where: { $0.id == self.file.id }), updated.isSynced {
                        self.file = updated
                        self.startTranscription()
                    }
                case .syncing(let p):
                    let info = p.totalFiles > 0 ? "Syncing \(p.syncedFiles)/\(p.totalFiles)..." : "Syncing..."
                    self.showProgress(info, sub: nil)
                case .failed(let msg):
                    self.showProgress("Sync failed", sub: msg)
                default: break
                }
            }
            .store(in: &cancellables)
    }

    private func setupTranscriptionBinding() {
        // dropFirst: 跳过 CurrentValueSubject 的当前值，避免收到上一个文件的残留 .completed 状态
        transcriptionManager.statePublisher
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] state in
                guard let self = self else { return }
                switch state {
                case .idle: break
                case .uploading(let p):
                    self.showProgress("Uploading audio... \(Int(p * 100))%", sub: nil)
                case .submitting:
                    self.showProgress("Submitting transcription...", sub: nil)
                case .processing(let status):
                    self.showProgress("Processing...", sub: status)
                case .completed(let results):
                    self.transcriptResults = results
                    // 存储结构化 JSON（保留 speaker/timestamp），用于缓存恢复
                    if let jsonData = try? JSONEncoder().encode(results),
                       let jsonStr = String(data: jsonData, encoding: .utf8) {
                        self.file.transcriptJSON = jsonStr
                        RecordingStore.shared.updateTranscript(id: self.file.id, transcript: jsonStr)
                    }
                    self.prepareAudioPlayer()
                    self.updateTabContent()
                case .failed(let msg):
                    self.showProgress("Transcription failed", sub: msg)
                }
            }
            .store(in: &cancellables)
    }

    private func showProgress(_ title: String, sub: String?) {
        emptyStateView.isHidden = true
        summaryContentLabel.isHidden = true
        transcriptStack.isHidden = true
        progressLabel.text = title
        progressLabel.isHidden = false
        progressSubLabel.text = sub ?? "This may take a few minutes"
        progressSubLabel.isHidden = false
    }

    // MARK: - Audio Playback

    private func prepareAudioPlayer() {
        guard let audioPath = RecordingStore.shared.resolveAbsolutePath(for: file) else {
            print("[FileDetail] Audio file not found, localPath=\(file.localPath ?? "nil")")
            return
        }

        print("[FileDetail] Loading audio: \(audioPath)")
        audioPlayerView.configure(audioPath: audioPath, duration: file.duration)
        audioPlayerView.isHidden = false
    }

    // MARK: - Transcript Display

    private func showTranscriptResults(_ results: [TranscriptionResult]) {
        transcriptStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for r in results {
            let entry = UIView()

            // Speaker + timestamp
            let headerLabel = UILabel()
            let time = formatSeconds(r.start ?? 0)
            let speaker = r.speakerId?.replacingOccurrences(of: "SPEAKER_", with: "Speaker ") ?? "Speaker"
            headerLabel.text = "\(speaker)  ·  \(time)"
            headerLabel.font = .systemFont(ofSize: 13)
            headerLabel.textColor = UIColor(hex: "#A3A3A3")
            headerLabel.translatesAutoresizingMaskIntoConstraints = false

            // Body text
            let bodyLabel = UILabel()
            bodyLabel.text = r.text
            bodyLabel.font = .systemFont(ofSize: 14)
            bodyLabel.textColor = UIColor(hex: "#3D3D3D")
            bodyLabel.numberOfLines = 0
            bodyLabel.translatesAutoresizingMaskIntoConstraints = false

            [headerLabel, bodyLabel].forEach { entry.addSubview($0) }
            NSLayoutConstraint.activate([
                headerLabel.topAnchor.constraint(equalTo: entry.topAnchor),
                headerLabel.leadingAnchor.constraint(equalTo: entry.leadingAnchor),
                headerLabel.trailingAnchor.constraint(equalTo: entry.trailingAnchor),
                bodyLabel.topAnchor.constraint(equalTo: headerLabel.bottomAnchor, constant: 12),
                bodyLabel.leadingAnchor.constraint(equalTo: entry.leadingAnchor),
                bodyLabel.trailingAnchor.constraint(equalTo: entry.trailingAnchor),
                bodyLabel.bottomAnchor.constraint(equalTo: entry.bottomAnchor),
            ])
            transcriptStack.addArrangedSubview(entry)
        }
    }

    private func formatSeconds(_ seconds: Double) -> String {
        let total = Int(seconds)
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        return String(format: "%02d:%02d:%02d", h, m, s)
    }

    // MARK: - Actions

    @objc private func backTapped() {
        navigationController?.popViewController(animated: true)
    }

    @objc private func showMoreActions() {
        let sheet = UIAlertController(title: nil, message: nil, preferredStyle: .actionSheet)
        sheet.addAction(UIAlertAction(title: "Export Audio", style: .default) { [weak self] _ in self?.handleExport() })
        if let summary = file.summaryText, !summary.isEmpty {
            sheet.addAction(UIAlertAction(title: "Copy Summary", style: .default) { _ in UIPasteboard.general.string = summary })
        }
        if !transcriptResults.isEmpty {
            sheet.addAction(UIAlertAction(title: "Copy Transcript", style: .default) { [weak self] _ in
                let plainText = self?.transcriptResults.map { $0.text ?? "" }.joined(separator: "\n\n") ?? ""
                UIPasteboard.general.string = plainText
            })
        }
        sheet.addAction(UIAlertAction(title: "Delete Recording", style: .destructive) { [weak self] _ in self?.handleDelete() })
        sheet.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        present(sheet, animated: true)
    }

    private func handleExport() {
        syncManager.exportAudio(file) { [weak self] result in
            DispatchQueue.main.async {
                switch result {
                case .success(let url):
                    self?.present(UIActivityViewController(activityItems: [url], applicationActivities: nil), animated: true)
                case .failure(let error):
                    let alert = UIAlertController(title: "Export Failed", message: error.localizedDescription, preferredStyle: .alert)
                    alert.addAction(UIAlertAction(title: "OK", style: .default))
                    self?.present(alert, animated: true)
                }
            }
        }
    }

    private func handleDelete() {
        let alert = UIAlertController(title: "Delete Recording", message: "This will permanently delete \"\(file.name)\".", preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "Delete", style: .destructive) { [weak self] _ in
            guard let self else { return }
            self.syncManager.deleteFile(self.file)
            self.navigationController?.popViewController(animated: true)
        })
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        present(alert, animated: true)
    }
}

