import UIKit
import Combine

/// App main interface: custom floating capsule Tab Bar (272x62, corner radius 999, semi-transparent white + blur)
final class MainTabBarController: UITabBarController {

    private let floatingBar = FloatingTabBarView()
    private var childNavs: [UINavigationController] = []
    private var cancellables = Set<AnyCancellable>()

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = PlaudTheme.backgroundPrimary
        setupChildControllers()
        setupFloatingBar()
        tabBar.isHidden = true // Hide native Tab Bar

        // Auto-reconnect hit a device locked by another account: offer the recovery flow
        // (lifecycle guide §3.3) — the connect sheet is not open on this path.
        DeviceManager.shared.recoveryOfferPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] device in
                let alert = UIAlertController(
                    title: "Device Locked",
                    message: "\(device.name) may still be locked by a previous account. Try to recover it?",
                    preferredStyle: .alert
                )
                alert.addAction(UIAlertAction(title: "Recover", style: .default) { _ in
                    DeviceManager.shared.startDeviceRecovery(device)
                })
                alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
                self?.present(alert, animated: true)
            }
            .store(in: &cancellables)

        // Cloud binding alerts (e.g. device bound to another account)
        DeviceManager.shared.cloudAlertPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] message in
                let alert = UIAlertController(title: "Device Binding", message: message, preferredStyle: .alert)
                alert.addAction(UIAlertAction(title: "OK", style: .default))
                self?.present(alert, animated: true)
            }
            .store(in: &cancellables)
    }

    private func setupChildControllers() {
        let homeNav = UINavigationController(rootViewController: HomeViewController())
        let filesNav = UINavigationController(rootViewController: FilesViewController())
        let settingsNav = UINavigationController(rootViewController: SettingsViewController())
        childNavs = [homeNav, filesNav, settingsNav]
        // The floating capsule lives on THIS controller's view, not on UIKit's tabBar, so
        // hidesBottomBarWhenPushed can't touch it. Drive it from the nav stack depth instead:
        // otherwise it stays on top of every pushed page (Scanning / Device Panel / File Detail).
        childNavs.forEach { $0.delegate = self }
        viewControllers = childNavs
    }

    private func setupFloatingBar() {
        floatingBar.translatesAutoresizingMaskIntoConstraints = false
        floatingBar.configure(
            items: [
                FloatingTabItem(title: "Home", icon: UIImage(named: "tab_home")),
                FloatingTabItem(title: "Files", icon: UIImage(named: "tab_files")),
                FloatingTabItem(title: "Settings", icon: UIImage(named: "tab_settings")),
            ],
            selectedIndex: 0
        )
        floatingBar.onTabSelected = { [weak self] index in
            self?.selectedIndex = index
        }
        view.addSubview(floatingBar)

        NSLayoutConstraint.activate([
            floatingBar.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            floatingBar.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -8),
            floatingBar.widthAnchor.constraint(equalToConstant: 272),
            floatingBar.heightAnchor.constraint(equalToConstant: 62),
        ])
    }

    override var selectedIndex: Int {
        didSet { floatingBar.updateSelection(selectedIndex) }
    }

    /// Show the capsule only on a tab's root page. Fades so a push doesn't look like a glitch.
    private func setFloatingBarHidden(_ hidden: Bool, animated: Bool) {
        let target: CGFloat = hidden ? 0 : 1
        guard floatingBar.alpha != target || floatingBar.isHidden != hidden else { return }
        floatingBar.isHidden = false
        UIView.animate(withDuration: animated ? 0.2 : 0) {
            self.floatingBar.alpha = target
        } completion: { _ in
            self.floatingBar.isHidden = hidden
        }
    }
}

// MARK: - UINavigationControllerDelegate

extension MainTabBarController: UINavigationControllerDelegate {
    func navigationController(
        _ navigationController: UINavigationController,
        willShow viewController: UIViewController,
        animated: Bool
    ) {
        let isRoot = navigationController.viewControllers.first === viewController
        setFloatingBarHidden(!isRoot, animated: animated)
    }

    func navigationController(
        _ navigationController: UINavigationController,
        didShow viewController: UIViewController,
        animated: Bool
    ) {
        // Re-sync after the transition: a cancelled swipe-back leaves willShow's guess stale.
        setFloatingBarHidden(navigationController.viewControllers.count > 1, animated: false)
    }
}

// MARK: - FloatingTabBarView

struct FloatingTabItem {
    let title: String
    let icon: UIImage?
}

final class FloatingTabBarView: UIView {

    var onTabSelected: ((Int) -> Void)?

    private var buttons: [UIButton] = []
    private var items: [FloatingTabItem] = []
    private var currentIndex = 0

    override init(frame: CGRect) {
        super.init(frame: frame)
        setupStyle()
    }
    required init?(coder: NSCoder) { fatalError() }

    private let blurContainer = UIView()

    private func setupStyle() {
        backgroundColor = .clear

        // Shadow on outer layer
        layer.shadowColor = UIColor.black.cgColor
        layer.shadowOpacity = 0.08
        layer.shadowOffset = CGSize(width: 0, height: 2)
        layer.shadowRadius = 16

        // Inner container handles corner radius + clipping
        blurContainer.backgroundColor = UIColor.white.withAlphaComponent(0.7)
        blurContainer.layer.cornerRadius = 31
        blurContainer.layer.masksToBounds = true
        blurContainer.translatesAutoresizingMaskIntoConstraints = false
        insertSubview(blurContainer, at: 0)

        let blur = UIVisualEffectView(effect: UIBlurEffect(style: .light))
        blur.translatesAutoresizingMaskIntoConstraints = false
        blur.isUserInteractionEnabled = false
        blurContainer.addSubview(blur)

        NSLayoutConstraint.activate([
            blurContainer.topAnchor.constraint(equalTo: topAnchor),
            blurContainer.bottomAnchor.constraint(equalTo: bottomAnchor),
            blurContainer.leadingAnchor.constraint(equalTo: leadingAnchor),
            blurContainer.trailingAnchor.constraint(equalTo: trailingAnchor),
            blur.topAnchor.constraint(equalTo: blurContainer.topAnchor),
            blur.bottomAnchor.constraint(equalTo: blurContainer.bottomAnchor),
            blur.leadingAnchor.constraint(equalTo: blurContainer.leadingAnchor),
            blur.trailingAnchor.constraint(equalTo: blurContainer.trailingAnchor),
        ])
    }

    func configure(items: [FloatingTabItem], selectedIndex: Int) {
        self.items = items
        self.currentIndex = selectedIndex
        buttons.forEach { $0.removeFromSuperview() }
        buttons.removeAll()

        let stack = UIStackView()
        stack.axis = .horizontal
        stack.distribution = .fillEqually
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)

        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 4),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -4),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
        ])

        for (i, item) in items.enumerated() {
            let btn = makeTabButton(item: item, index: i, isSelected: i == selectedIndex)
            stack.addArrangedSubview(btn)
            buttons.append(btn)
        }
    }

    func updateSelection(_ index: Int) {
        guard index != currentIndex, index < buttons.count else { return }
        currentIndex = index
        for (i, btn) in buttons.enumerated() {
            let isSelected = i == index
            let color: UIColor = isSelected ? .black : UIColor(hex: "#7A7A7A")
            btn.backgroundColor = isSelected ? UIColor(hex: "#3D3D3D").withAlphaComponent(0.12) : .clear
            // Update icon + label color in stack
            if let stack = btn.subviews.first(where: { $0 is UIStackView }) as? UIStackView {
                (stack.arrangedSubviews.first as? UIImageView)?.tintColor = color
                (stack.arrangedSubviews.last as? UILabel)?.textColor = color
            }
        }
    }

    private func makeTabButton(item: FloatingTabItem, index: Int, isSelected: Bool) -> UIButton {
        let btn = UIButton(type: .custom)
        btn.tag = index

        // Vertical layout: icon + label
        let iconView = UIImageView(image: item.icon?.withRenderingMode(.alwaysTemplate))
        iconView.contentMode = .scaleAspectFit
        iconView.translatesAutoresizingMaskIntoConstraints = false

        let label = UILabel()
        label.text = item.title
        label.font = .systemFont(ofSize: 11, weight: .regular)
        label.textAlignment = .center
        label.translatesAutoresizingMaskIntoConstraints = false

        let stack = UIStackView(arrangedSubviews: [iconView, label])
        stack.axis = .vertical
        stack.alignment = .center
        stack.spacing = 2
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.isUserInteractionEnabled = false
        btn.addSubview(stack)

        NSLayoutConstraint.activate([
            iconView.widthAnchor.constraint(equalToConstant: 24),
            iconView.heightAnchor.constraint(equalToConstant: 24),
            stack.centerXAnchor.constraint(equalTo: btn.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: btn.centerYAnchor),
        ])

        let color: UIColor = isSelected ? .black : UIColor(hex: "#7A7A7A")
        iconView.tintColor = color
        label.textColor = color
        btn.backgroundColor = isSelected ? UIColor(hex: "#3D3D3D").withAlphaComponent(0.12) : .clear
        btn.layer.cornerRadius = 27
        btn.clipsToBounds = true

        btn.addTarget(self, action: #selector(tabTapped(_:)), for: .touchUpInside)
        return btn
    }

    @objc private func tabTapped(_ sender: UIButton) {
        let index = sender.tag
        updateSelection(index)
        onTabSelected?(index)
    }
}
