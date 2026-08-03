import UIKit

/// Plaud design system — colors and fonts
enum PlaudTheme {

    // MARK: - Colors

    /// Page background #f9f9f9
    static let backgroundPrimary = UIColor(hex: "#f9f9f9")
    /// Primary text #1f1f1f
    static let labelPrimary = UIColor(hex: "#1f1f1f")
    /// Auxiliary/disabled text #a3a3a3
    static let labelQuaternary = UIColor(hex: "#a3a3a3")
    /// Secondary text #858585
    static let gray5 = UIColor(hex: "#858585")
    /// Border/separator #ebebeb
    static let separator = UIColor(hex: "#ebebeb")
    /// Inactive page indicator dot #d6d6d6
    static let gray2 = UIColor(hex: "#d6d6d6")
    /// Overlay
    static let overlay = UIColor.black.withAlphaComponent(0.4)

    // MARK: - Fonts

    /// 36px Light — Welcome large title
    static func largeTitle() -> UIFont { .systemFont(ofSize: 36, weight: .light) }
    /// 24px Light — Dialog title "Connect Device" / Success page title
    static func title2() -> UIFont { .systemFont(ofSize: 24, weight: .light) }
    /// 20px Light — Device name
    static func headline() -> UIFont { .systemFont(ofSize: 20, weight: .light) }
    /// 16px Regular — Body text
    static func body() -> UIFont { .systemFont(ofSize: 16, weight: .regular) }
    /// 16px SemiBold — Button text
    static func bodyEmphasized() -> UIFont { .systemFont(ofSize: 16, weight: .semibold) }
    /// 14px Regular — SN, subtitle
    static func footnote() -> UIFont { .systemFont(ofSize: 14, weight: .regular) }
    /// 13px Regular — Small hint text
    static func caption() -> UIFont { .systemFont(ofSize: 13, weight: .regular) }

    // MARK: - Common Components

    /// Standard primary button (black background, white text, 354x48, radius 12)
    static func makePrimaryButton(title: String) -> UIButton {
        let btn = UIButton(type: .custom)
        btn.setTitle(title, for: .normal)
        btn.setTitleColor(.white, for: .normal)
        btn.titleLabel?.font = bodyEmphasized()
        btn.backgroundColor = .black
        btn.layer.cornerRadius = 12
        btn.translatesAutoresizingMaskIntoConstraints = false
        return btn
    }

    /// Inverted button (white background, black text, for Welcome page)
    static func makeSecondaryButton(title: String) -> UIButton {
        let btn = UIButton(type: .custom)
        btn.setTitle(title, for: .normal)
        btn.setTitleColor(labelPrimary, for: .normal)
        btn.titleLabel?.font = body()
        btn.backgroundColor = .white
        btn.layer.cornerRadius = 12
        btn.translatesAutoresizingMaskIntoConstraints = false
        return btn
    }
}

// MARK: - UIColor hex extension

extension UIColor {
    convenience init(hex: String) {
        let hex = hex.trimmingCharacters(in: .init(charactersIn: "#"))
        let scanner = Scanner(string: hex)
        var rgb: UInt64 = 0
        scanner.scanHexInt64(&rgb)
        let r = CGFloat((rgb >> 16) & 0xFF) / 255
        let g = CGFloat((rgb >> 8) & 0xFF) / 255
        let b = CGFloat(rgb & 0xFF) / 255
        self.init(red: r, green: g, blue: b, alpha: 1)
    }
}
