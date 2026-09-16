import UIKit

extension UIView {
    /// Horizontal shake animation (for input validation failure feedback)
    func shake() {
        let anim = CAKeyframeAnimation(keyPath: "transform.translation.x")
        anim.timingFunction = CAMediaTimingFunction(name: .linear)
        anim.duration = 0.4
        anim.values = [-10, 10, -8, 8, -5, 5, 0]
        layer.add(anim, forKey: "shake")
    }
}

extension String {
    /// JWT base64url -> standard base64 (with padding)
    func base64Padded() -> String {
        var s = self.replacingOccurrences(of: "-", with: "+")
                     .replacingOccurrences(of: "_", with: "/")
        let remainder = s.count % 4
        if remainder > 0 { s += String(repeating: "=", count: 4 - remainder) }
        return s
    }
}
