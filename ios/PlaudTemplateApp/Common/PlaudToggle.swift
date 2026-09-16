import UIKit

/// Custom Toggle (Figma: 48x26, cornerRadius 6, square knob 22x22 cornerRadius 4)
final class PlaudToggle: UIControl {

    var isOn: Bool = false {
        didSet { updateAppearance(animated: false) }
    }

    var onToggle: ((Bool) -> Void)?

    private let track = UIView()
    private let knob = UIView()
    private var knobLeading: NSLayoutConstraint!
    private var knobTrailing: NSLayoutConstraint!

    override init(frame: CGRect) {
        super.init(frame: frame)
        setup()
    }
    required init?(coder: NSCoder) { fatalError() }

    private func setup() {
        // Track
        track.layer.cornerRadius = 6
        track.translatesAutoresizingMaskIntoConstraints = false
        track.isUserInteractionEnabled = false
        addSubview(track)

        // Knob
        knob.backgroundColor = .white
        knob.layer.cornerRadius = 4
        knob.translatesAutoresizingMaskIntoConstraints = false
        knob.isUserInteractionEnabled = false
        addSubview(knob)

        knobLeading = knob.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2)
        knobTrailing = knob.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -2)

        NSLayoutConstraint.activate([
            track.topAnchor.constraint(equalTo: topAnchor),
            track.bottomAnchor.constraint(equalTo: bottomAnchor),
            track.leadingAnchor.constraint(equalTo: leadingAnchor),
            track.trailingAnchor.constraint(equalTo: trailingAnchor),

            knob.centerYAnchor.constraint(equalTo: centerYAnchor),
            knob.widthAnchor.constraint(equalToConstant: 22),
            knob.heightAnchor.constraint(equalToConstant: 22),
        ])

        updateAppearance(animated: false)
        addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(tapped)))
    }

    private func updateAppearance(animated: Bool) {
        track.backgroundColor = isOn ? .black : UIColor(hex: "#D6D6D6")
        knobLeading.isActive = !isOn
        knobTrailing.isActive = isOn

        if animated {
            UIView.animate(withDuration: 0.2) { self.layoutIfNeeded() }
        }
    }

    @objc private func tapped() {
        isOn.toggle()
        updateAppearance(animated: true)
        onToggle?(isOn)
        sendActions(for: .valueChanged)
    }
}
