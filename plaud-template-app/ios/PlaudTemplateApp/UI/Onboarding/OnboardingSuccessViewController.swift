import UIKit

/// Onboarding Screen 5 — Bind Successful
///
final class OnboardingSuccessViewController: UIViewController {

    // MARK: - Views

    /// Top blue decorative ellipse
    private let bgEllipseView: UIImageView = {
        let iv = UIImageView(image: UIImage(named: "success_bg_ellipse"))
        iv.contentMode = .scaleAspectFill
        iv.clipsToBounds = true
        iv.translatesAutoresizingMaskIntoConstraints = false
        return iv
    }()

    /// Success checkmark icon
    private let checkIconView: UIImageView = {
        let iv = UIImageView(image: UIImage(named: "icon_success_check"))
        iv.contentMode = .scaleAspectFit
        iv.translatesAutoresizingMaskIntoConstraints = false
        return iv
    }()

    /// "You're all set!"
    private let titleLabel: UILabel = {
        let l = UILabel()
        l.text = "You're all set!"
        l.font = PlaudTheme.title2()
        l.textColor = PlaudTheme.labelPrimary
        l.textAlignment = .center
        l.translatesAutoresizingMaskIntoConstraints = false
        return l
    }()

    /// Subtitle
    private let subtitleLabel: UILabel = {
        let l = UILabel()
        l.text = "Your device is connected and ready to use."
        l.font = PlaudTheme.body()
        l.textColor = PlaudTheme.labelQuaternary
        l.textAlignment = .center
        l.numberOfLines = 2
        l.translatesAutoresizingMaskIntoConstraints = false
        return l
    }()

    /// "Explore Intelligence" button
    private lazy var exploreButton: UIButton = {
        let btn = PlaudTheme.makePrimaryButton(title: "Explore Intelligence")
        btn.addTarget(self, action: #selector(exploreTapped), for: .touchUpInside)
        return btn
    }()

    // MARK: - Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = PlaudTheme.backgroundPrimary
        setupLayout()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        animateIn()
    }

    // MARK: - Layout

    private func setupLayout() {
        // Initially transparent, waiting for animation
        [checkIconView, titleLabel, subtitleLabel].forEach { $0.alpha = 0 }

        [bgEllipseView, checkIconView, titleLabel, subtitleLabel, exploreButton]
            .forEach { view.addSubview($0) }

        NSLayoutConstraint.activate([
            // Top decorative ellipse
            bgEllipseView.topAnchor.constraint(equalTo: view.topAnchor, constant: -30),
            bgEllipseView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            bgEllipseView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            bgEllipseView.heightAnchor.constraint(equalToConstant: 280),

            // Checkmark icon
            checkIconView.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            checkIconView.centerYAnchor.constraint(equalTo: view.centerYAnchor, constant: -80),
            checkIconView.widthAnchor.constraint(equalToConstant: 80),
            checkIconView.heightAnchor.constraint(equalToConstant: 80),

            // Title
            titleLabel.topAnchor.constraint(equalTo: checkIconView.bottomAnchor, constant: 32),
            titleLabel.centerXAnchor.constraint(equalTo: view.centerXAnchor),

            // Subtitle
            subtitleLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 12),
            subtitleLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 24),
            subtitleLabel.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -24),

            // Explore button
            exploreButton.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -20),
            exploreButton.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 24),
            exploreButton.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -24),
            exploreButton.heightAnchor.constraint(equalToConstant: 48),
        ])
    }

    // MARK: - Entry Animation

    private func animateIn() {
        UIView.animate(withDuration: 0.5, delay: 0.1,
                       usingSpringWithDamping: 0.7, initialSpringVelocity: 0.5,
                       options: .curveEaseOut) {
            self.checkIconView.alpha = 1
        }
        UIView.animate(withDuration: 0.4, delay: 0.35) {
            self.titleLabel.alpha = 1
        }
        UIView.animate(withDuration: 0.4, delay: 0.5) {
            self.subtitleLabel.alpha = 1
        }
    }

    // MARK: - Actions

    @objc private func exploreTapped() {
        let tabBar = MainTabBarController()
        tabBar.modalPresentationStyle = .fullScreen
        view.window?.rootViewController = tabBar
    }
}
