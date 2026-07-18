import UIKit
import Combine

/// File list page: grouped by date, shows all files (including unsynced), shares SyncManager state
final class FilesViewController: UIViewController {

    // MARK: - SDK Integration
    private let syncManager: SyncManagerProtocol = SyncManager.shared
    private var cancellables = Set<AnyCancellable>()

    // MARK: - Views
    private let scrollView = UIScrollView()
    private let contentView = UIView()

    private let titleLabel: UILabel = {
        let l = UILabel()
        l.text = "Files"
        l.font = .systemFont(ofSize: 44, weight: .light)
        l.textColor = .black
        l.translatesAutoresizingMaskIntoConstraints = false
        return l
    }()

    private let searchButton: UIButton = {
        let btn = UIButton(type: .system)
        btn.setImage(UIImage(systemName: "magnifyingglass", withConfiguration: UIImage.SymbolConfiguration(pointSize: 20)), for: .normal)
        btn.tintColor = .black
        btn.translatesAutoresizingMaskIntoConstraints = false
        return btn
    }()

    /// Sync banner (shares SyncManager state with Home)
    private let syncBanner = SyncBannerView()

    private let fileStack: UIStackView = {
        let s = UIStackView()
        s.axis = .vertical
        s.spacing = 0
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

        syncBanner.translatesAutoresizingMaskIntoConstraints = false
        syncBanner.isHidden = true

        [titleLabel, searchButton, syncBanner, fileStack, emptyLabel].forEach { contentView.addSubview($0) }

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

            searchButton.centerYAnchor.constraint(equalTo: titleLabel.centerYAnchor),
            searchButton.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -24),

            syncBanner.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 24),
            syncBanner.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 24),
            syncBanner.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -24),

            fileStack.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 40),
            fileStack.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 24),
            fileStack.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -24),
            fileStack.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -120),

            emptyLabel.centerXAnchor.constraint(equalTo: contentView.centerXAnchor),
            emptyLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 80),
        ])
    }

    // MARK: - SDK Bindings

    private func setupBindings() {
        // File list (all files, including unsynced)
        syncManager.filesPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] files in self?.updateFiles(files) }
            .store(in: &cancellables)

        // Sync state -> Banner (shared SyncManager state)
        syncManager.statePublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] state in self?.updateSyncBanner(state) }
            .store(in: &cancellables)
    }

    private func updateFiles(_ files: [RecordingFile]) {
        fileStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        emptyLabel.isHidden = !files.isEmpty
        fileStack.isHidden = files.isEmpty

        let groups = groupByDate(files)
        for (i, group) in groups.enumerated() {
            if i > 0 {
                let spacer = UIView()
                spacer.translatesAutoresizingMaskIntoConstraints = false
                spacer.heightAnchor.constraint(equalToConstant: 40).isActive = true
                fileStack.addArrangedSubview(spacer)
            }

            let header = UILabel()
            header.text = group.date
            header.font = .systemFont(ofSize: 24, weight: .light)
            header.textColor = UIColor(hex: "#3D3D3D")
            fileStack.addArrangedSubview(header)

            let headerSpacer = UIView()
            headerSpacer.translatesAutoresizingMaskIntoConstraints = false
            headerSpacer.heightAnchor.constraint(equalToConstant: 20).isActive = true
            fileStack.addArrangedSubview(headerSpacer)

            let itemStack = UIStackView()
            itemStack.axis = .vertical
            itemStack.spacing = 8
            for file in group.files {
                let row = FileRowView(file: file)
                row.onTapped = { [weak self] in self?.openFile(file) }
                itemStack.addArrangedSubview(row)
            }
            fileStack.addArrangedSubview(itemStack)
        }
    }

    private func updateSyncBanner(_ state: SyncState) {
        switch state {
        case .syncing(let progress):
            syncBanner.configure(progress: progress, isWiFi: false)
            if syncBanner.isHidden {
                syncBanner.alpha = 0
                syncBanner.isHidden = false
                UIView.animate(withDuration: 0.25) { self.syncBanner.alpha = 1 }
            }
        case .wifiTransferring(let progress):
            syncBanner.configure(progress: progress, isWiFi: true)
            if syncBanner.isHidden {
                syncBanner.alpha = 0
                syncBanner.isHidden = false
                UIView.animate(withDuration: 0.25) { self.syncBanner.alpha = 1 }
            }
        case .wifiConnecting:
            break // Handled by FastTransferSheet
        case .completed:
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                UIView.animate(withDuration: 0.25) { self.syncBanner.alpha = 0 } completion: { _ in
                    self.syncBanner.isHidden = true
                }
            }
        default:
            syncBanner.isHidden = true
        }
    }

    // MARK: - Group by Date

    private func groupByDate(_ files: [RecordingFile]) -> [(date: String, files: [RecordingFile])] {
        let calendar = Calendar.current
        let formatter = DateFormatter()
        formatter.dateFormat = "EEE, MMM d"

        var result: [(String, [RecordingFile])] = []
        var keyToIndex: [String: Int] = [:]

        for file in files.sorted(by: { $0.createdAt > $1.createdAt }) {
            let key: String
            if calendar.isDateInToday(file.createdAt) {
                key = "Today"
            } else if calendar.isDateInYesterday(file.createdAt) {
                key = "Yesterday"
            } else {
                key = formatter.string(from: file.createdAt)
            }

            if let idx = keyToIndex[key] {
                result[idx].1.append(file)
            } else {
                keyToIndex[key] = result.count
                result.append((key, [file]))
            }
        }
        return result.map { (date: $0.0, files: $0.1) }
    }

    // MARK: - Actions

    private func openFile(_ file: RecordingFile) {
        let detailVC = FileDetailViewController(file: file, syncManager: syncManager)
        navigationController?.pushViewController(detailVC, animated: true)
    }
}
