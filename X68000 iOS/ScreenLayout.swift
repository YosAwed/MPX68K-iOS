//
//  ScreenLayout.swift
//  MPX68K for iOS
//
//  View controllers for the adaptive layout:
//  - ScreenViewController shows the emulator (SKView) aspect-fit in its safe area.
//  - ControlPanelViewController hosts the touch controls. It lies on top of the
//    screen, passing touches through, or takes its own side of the fold when
//    iPhone Duo is partially folded (see GameViewController).
//

import UIKit
import SpriteKit

final class ScreenViewController: UIViewController {

    let skView = SKView(frame: .zero)
    private var aspectConstraint: NSLayoutConstraint?

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        skView.translatesAutoresizingMaskIntoConstraints = false
        skView.backgroundColor = .black
        view.addSubview(skView)

        let guide = view.safeAreaLayoutGuide
        let fillWidth = skView.widthAnchor.constraint(equalTo: guide.widthAnchor)
        fillWidth.priority = .defaultHigh
        let fillHeight = skView.heightAnchor.constraint(equalTo: guide.heightAnchor)
        fillHeight.priority = .defaultHigh
        NSLayoutConstraint.activate([
            skView.centerXAnchor.constraint(equalTo: guide.centerXAnchor),
            skView.centerYAnchor.constraint(equalTo: guide.centerYAnchor),
            skView.widthAnchor.constraint(lessThanOrEqualTo: guide.widthAnchor),
            skView.heightAnchor.constraint(lessThanOrEqualTo: guide.heightAnchor),
            fillWidth,
            fillHeight,
        ])
    }

    /// Keeps the SKView at the scene's aspect ratio so the aspect-fit scene fills it.
    func setAspectRatio(_ size: CGSize) {
        guard size.width > 0, size.height > 0 else { return }
        loadViewIfNeeded()
        aspectConstraint?.isActive = false
        aspectConstraint = skView.widthAnchor.constraint(equalTo: skView.heightAnchor,
                                                         multiplier: size.width / size.height)
        aspectConstraint?.isActive = true
    }
}

final class ControlPanelViewController: UIViewController {
    override func loadView() {
        view = PassThroughView()
    }
}

/// Only its visible subviews take touches; everything else falls through.
final class PassThroughView: UIView {
    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        subviews.contains {
            !$0.isHidden && $0.alpha > 0.01 && $0.isUserInteractionEnabled
                && $0.point(inside: convert(point, to: $0), with: event)
        }
    }
}

/// Trackpad surface shown in the control panel when it has its own side of the fold.
final class TrackpadSurfaceView: UIView {
    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = UIColor.white.withAlphaComponent(0.06)
        layer.cornerRadius = 20
        layer.borderWidth = 1
        layer.borderColor = UIColor.white.withAlphaComponent(0.2).cgColor

        let label = UILabel()
        label.text = "トラックパッド"
        label.font = .preferredFont(forTextStyle: .footnote)
        label.textColor = UIColor.white.withAlphaComponent(0.4)
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: centerXAnchor),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        isAccessibilityElement = true
        accessibilityLabel = "トラックパッド"
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}
