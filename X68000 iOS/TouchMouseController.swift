//
//  TouchMouseController.swift
//  MPX68K for iOS
//
//  Trackpad-style mouse on top of the SKView:
//  - one-finger drag moves the X68000 mouse (relative)
//  - tap = left click, two-finger tap = right click
//  - press and hold, then drag = left-button drag
//  - pointer hover (iPad trackpad / Apple Pencil) moves the mouse
//
//  Movement is fed to X68MouseController in capture mode, the same relative
//  path the macOS version uses for its captured mouse.
//

import UIKit
import SpriteKit

final class TouchMouseController: NSObject, UIGestureRecognizerDelegate {

    private weak var view: SKView?
    private let sceneProvider: () -> GameScene?

    private var recognizers: [UIGestureRecognizer] = []
    private var lastPanTranslation: CGPoint = .zero
    private var lastHoverLocation: CGPoint?
    private var isDragging = false

    var isEnabled: Bool = true {
        didSet {
            recognizers.forEach { $0.isEnabled = isEnabled }
            if !isEnabled { endDrag() }
        }
    }

    /// `view` is the emulator screen; it is used as a touch surface and for scaling.
    init(view: SKView, scene: @escaping () -> GameScene?) {
        self.view = view
        self.sceneProvider = scene
        super.init()
        addSurface(view)
    }

    /// Adds the trackpad gestures to another view (e.g. a trackpad panel).
    func addSurface(_ surface: UIView) {
        let pan = UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
        pan.maximumNumberOfTouches = 1
        pan.delegate = self

        let tap = UITapGestureRecognizer(target: self, action: #selector(handleTap(_:)))
        tap.numberOfTouchesRequired = 1

        let twoFingerTap = UITapGestureRecognizer(target: self, action: #selector(handleTwoFingerTap(_:)))
        twoFingerTap.numberOfTouchesRequired = 2

        let longPress = UILongPressGestureRecognizer(target: self, action: #selector(handleLongPress(_:)))
        longPress.minimumPressDuration = 0.35
        longPress.delegate = self

        let hover = UIHoverGestureRecognizer(target: self, action: #selector(handleHover(_:)))

        for recognizer in [pan, tap, twoFingerTap, longPress, hover] as [UIGestureRecognizer] {
            // Let the scene keep receiving touches (CRT overlay etc.)
            recognizer.cancelsTouchesInView = false
            recognizer.isEnabled = isEnabled
            surface.addGestureRecognizer(recognizer)
            recognizers.append(recognizer)
        }
    }

    // MARK: - Mouse output

    private var mouse: X68MouseController? {
        guard let mouse = sceneProvider()?.mouseController else { return nil }
        if !mouse.isCaptureMode {
            mouse.enableCaptureMode()
        }
        return mouse
    }

    /// View points → X68000 screen pixels, so the pointer tracks the finger.
    private var pointsToPixels: CGFloat {
        guard let view, let scene = sceneProvider(), scene.size.width > 0, scene.size.height > 0 else { return 1 }
        let fit = min(view.bounds.width / scene.size.width, view.bounds.height / scene.size.height)
        let displayedWidth = scene.size.width * fit
        let screenWidth = CGFloat(max(X68000_GetScreenWidth(), 1))
        return displayedWidth > 0 ? screenWidth / displayedWidth : 1
    }

    private func move(by delta: CGPoint) {
        guard let mouse, delta != .zero else { return }
        let scale = pointsToPixels
        // X68MouseController expects y up (like macOS -deltaY)
        mouse.addDeltas(delta.x * scale, -delta.y * scale)
    }

    private func click(_ button: Int) {
        guard let mouse else { return }
        mouse.Click(button, true)
        mouse.Click(button, false)
    }

    private func endDrag() {
        guard isDragging else { return }
        isDragging = false
        mouse?.Click(0, false)
    }

    // MARK: - Gestures

    @objc private func handlePan(_ gesture: UIPanGestureRecognizer) {
        let translation = gesture.translation(in: gesture.view)
        switch gesture.state {
        case .began:
            lastPanTranslation = translation
        case .changed:
            move(by: CGPoint(x: translation.x - lastPanTranslation.x,
                             y: translation.y - lastPanTranslation.y))
            lastPanTranslation = translation
        default:
            lastPanTranslation = .zero
        }
    }

    @objc private func handleTap(_ gesture: UITapGestureRecognizer) {
        guard gesture.state == .recognized else { return }
        click(0)
    }

    @objc private func handleTwoFingerTap(_ gesture: UITapGestureRecognizer) {
        guard gesture.state == .recognized else { return }
        click(1)
    }

    @objc private func handleLongPress(_ gesture: UILongPressGestureRecognizer) {
        switch gesture.state {
        case .began:
            isDragging = true
            mouse?.Click(0, true)
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
        case .ended, .cancelled, .failed:
            endDrag()
        default:
            break
        }
    }

    @objc private func handleHover(_ gesture: UIHoverGestureRecognizer) {
        let location = gesture.location(in: gesture.view)
        switch gesture.state {
        case .began:
            lastHoverLocation = location
        case .changed:
            if let last = lastHoverLocation {
                move(by: CGPoint(x: location.x - last.x, y: location.y - last.y))
            }
            lastHoverLocation = location
        default:
            lastHoverLocation = nil
        }
    }

    // MARK: - UIGestureRecognizerDelegate

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        // Press-and-hold drag: the long press holds the button while the pan moves.
        let pair: Set<ObjectIdentifier> = [ObjectIdentifier(gestureRecognizer), ObjectIdentifier(other)]
        return recognizers.contains { $0 is UIPanGestureRecognizer && pair.contains(ObjectIdentifier($0)) }
            && recognizers.contains { $0 is UILongPressGestureRecognizer && pair.contains(ObjectIdentifier($0)) }
    }
}
