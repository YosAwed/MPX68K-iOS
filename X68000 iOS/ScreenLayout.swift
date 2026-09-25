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
    private var centerYConstraint: NSLayoutConstraint?
    private var topConstraint: NSLayoutConstraint?
    private var widthConstraints: [NSLayoutConstraint] = []

    /// Keeps the top corners of the screen clear of the display's rounded corners.
    private static let topAlignedInset: CGFloat = 12

    /// Pin the screen to the top of the safe area (portrait, controls below) instead of centring it.
    var alignsToTop = false {
        didSet {
            guard alignsToTop != oldValue, isViewLoaded else { return }
            applyAlignment()
        }
    }

    private func applyAlignment() {
        centerYConstraint?.isActive = !alignsToTop
        topConstraint?.isActive = alignsToTop
        let inset = alignsToTop ? Self.topAlignedInset : 0
        topConstraint?.constant = inset
        widthConstraints.forEach { $0.constant = -2 * inset }
    }

    private let bezel = MonitorBezelView()
    /// White glow used by the CRT power on/off effect.
    private let flash = UIView()
    private(set) var isPoweredOn = true

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        bezel.frame = view.bounds
        bezel.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(bezel)
        skView.translatesAutoresizingMaskIntoConstraints = false
        skView.backgroundColor = .black
        view.addSubview(skView)
        flash.backgroundColor = .white
        flash.alpha = 0
        flash.isUserInteractionEnabled = false
        view.addSubview(flash)

        let guide = view.safeAreaLayoutGuide
        let fillWidth = skView.widthAnchor.constraint(equalTo: guide.widthAnchor)
        fillWidth.priority = .defaultHigh
        let maxWidth = skView.widthAnchor.constraint(lessThanOrEqualTo: guide.widthAnchor)
        widthConstraints = [fillWidth, maxWidth]
        let fillHeight = skView.heightAnchor.constraint(equalTo: guide.heightAnchor)
        fillHeight.priority = .defaultHigh
        centerYConstraint = skView.centerYAnchor.constraint(equalTo: guide.centerYAnchor)
        topConstraint = skView.topAnchor.constraint(equalTo: guide.topAnchor)
        applyAlignment()
        NSLayoutConstraint.activate([
            skView.centerXAnchor.constraint(equalTo: guide.centerXAnchor),
            maxWidth,
            skView.heightAnchor.constraint(lessThanOrEqualTo: guide.heightAnchor),
            fillWidth,
            fillHeight,
        ])
    }

    /// Clips the screen during the CRT effect. The picture itself is never scaled
    /// (scaling the Metal-backed SKView resamples it and looks blurred).
    private let crtMask = UIView()

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        bezel.screenFrame = skView.frame
        if isPoweredOn && skView.mask == nil {
            flash.frame = skView.frame
        }
    }

    // MARK: - CRT power effect

    private enum BeamShape { case full, line, dot }

    /// The visible part of the screen for a beam shape, in the SKView's coordinates.
    private func beamRect(_ shape: BeamShape) -> CGRect {
        let bounds = skView.bounds
        switch shape {
        case .full:
            return bounds
        case .line:
            return CGRect(x: bounds.minX, y: bounds.midY - 1, width: bounds.width, height: 2)
        case .dot:
            return CGRect(x: bounds.midX - 3, y: bounds.midY - 1, width: 6, height: 2)
        }
    }

    private func setBeam(_ shape: BeamShape) {
        let rect = beamRect(shape)
        crtMask.frame = rect
        flash.frame = rect.offsetBy(dx: skView.frame.minX, dy: skView.frame.minY)
    }

    private func beginEffect(from shape: BeamShape) {
        skView.layer.removeAllAnimations()
        crtMask.layer.removeAllAnimations()
        flash.layer.removeAllAnimations()
        crtMask.backgroundColor = .white
        skView.mask = crtMask
        setBeam(shape)
    }

    /// Collapses the picture to a bright horizontal line, then a dot, like a CRT switching off.
    func powerOff() {
        guard isPoweredOn else { return }
        isPoweredOn = false
        beginEffect(from: .full)
        flash.alpha = 0
        UIView.animateKeyframes(withDuration: 0.35, delay: 0, options: [.calculationModeLinear]) {
            UIView.addKeyframe(withRelativeStartTime: 0, relativeDuration: 0.55) {
                self.setBeam(.line)
                self.flash.alpha = 0.9
            }
            UIView.addKeyframe(withRelativeStartTime: 0.55, relativeDuration: 0.45) {
                self.setBeam(.dot)
                self.flash.alpha = 0
            }
        }
    }

    /// Grows a bright dot into a line and then the full picture, like a CRT switching on.
    func powerOn() {
        guard !isPoweredOn else { return }
        isPoweredOn = true
        beginEffect(from: .dot)
        flash.alpha = 1
        UIView.animateKeyframes(withDuration: 0.45, delay: 0, options: [.calculationModeLinear]) {
            UIView.addKeyframe(withRelativeStartTime: 0, relativeDuration: 0.35) {
                self.setBeam(.line)
            }
            UIView.addKeyframe(withRelativeStartTime: 0.35, relativeDuration: 0.65) {
                self.setBeam(.full)
                self.flash.alpha = 0
            }
        } completion: { _ in
            if self.isPoweredOn {
                self.skView.mask = nil
                self.flash.frame = self.skView.frame
            }
        }
    }

    /// Shows the picture immediately (e.g. after moving to the outer display).
    func resetPower() {
        isPoweredOn = true
        crtMask.layer.removeAllAnimations()
        flash.layer.removeAllAnimations()
        skView.mask = nil
        flash.alpha = 0
        flash.frame = skView.frame
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

/// Fills the space around the emulator screen with a dark monitor bezel
/// (HIG: add artwork to letterbox/pillarbox areas instead of leaving them black).
final class MonitorBezelView: UIView {
    /// The emulator screen's frame in this view's coordinates.
    var screenFrame: CGRect = .zero {
        didSet { if screenFrame != oldValue { setNeedsDisplay() } }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        isOpaque = true
        contentMode = .redraw
        isUserInteractionEnabled = false
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func draw(_ rect: CGRect) {
        guard let context = UIGraphicsGetCurrentContext() else { return }
        let colorSpace = CGColorSpaceCreateDeviceRGB()

        // Cabinet: soft vertical gradient.
        let cabinet = [UIColor(white: 0.16, alpha: 1).cgColor, UIColor(white: 0.07, alpha: 1).cgColor] as CFArray
        if let gradient = CGGradient(colorsSpace: colorSpace, colors: cabinet, locations: [0, 1]) {
            context.drawLinearGradient(gradient, start: CGPoint(x: 0, y: bounds.minY),
                                       end: CGPoint(x: 0, y: bounds.maxY), options: [])
        }
        guard !screenFrame.isEmpty else { return }

        // Bezel around the tube, with a highlight on the upper edge.
        let bezelInset: CGFloat = -10
        let bezelRect = screenFrame.insetBy(dx: bezelInset, dy: bezelInset).intersection(bounds)
        let bezelPath = UIBezierPath(roundedRect: bezelRect, cornerRadius: 14)
        UIColor(white: 0.04, alpha: 1).setFill()
        bezelPath.fill()
        context.saveGState()
        bezelPath.addClip()
        let rim = [UIColor(white: 1, alpha: 0.10).cgColor, UIColor(white: 1, alpha: 0).cgColor] as CFArray
        if let gradient = CGGradient(colorsSpace: colorSpace, colors: rim, locations: [0, 1]) {
            context.drawLinearGradient(gradient, start: CGPoint(x: 0, y: bezelRect.minY),
                                       end: CGPoint(x: 0, y: bezelRect.minY + 24), options: [])
        }
        context.restoreGState()
        UIColor(white: 1, alpha: 0.08).setStroke()
        bezelPath.lineWidth = 1
        bezelPath.stroke()

        // Power lamp below the bottom-right corner of the screen when there is room.
        let lampY = bezelRect.maxY + 12
        if lampY + 4 < bounds.maxY {
            let lamp = CGRect(x: bezelRect.maxX - 18, y: lampY, width: 8, height: 4)
            context.setShadow(offset: .zero, blur: 6, color: UIColor.systemGreen.withAlphaComponent(0.8).cgColor)
            UIColor.systemGreen.setFill()
            UIBezierPath(roundedRect: lamp, cornerRadius: 2).fill()
        }
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
