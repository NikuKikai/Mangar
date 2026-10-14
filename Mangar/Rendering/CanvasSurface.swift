import MetalKit
import SwiftUI
import UIKit

struct CanvasSurfaceRepresentable: UIViewRepresentable {
    @ObservedObject var session: EditorSession

    func makeUIView(context: Context) -> CanvasSurface {
        let view = CanvasSurface(frame: .zero, device: session.renderer.device)
        view.session = session
        session.renderer.attach(view)
        return view
    }

    func updateUIView(_ uiView: CanvasSurface, context: Context) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        uiView.session = session
        session.renderer.viewportTintLayerID = session.showsTargetTint ? session.selectedLayerID : nil
        session.renderer.viewportTintTarget = session.selectedEditTarget
        session.renderer.showsSelectionTint = session.showsSelectionTint
        uiView.refreshBrushCursor()
        uiView.setNeedsDisplay()
    }
}

final class CanvasSurface: MTKView {
    weak var session: EditorSession? {
        didSet {
            if oldValue !== session {
                historyTap = nil
                hideBrushCursor()
            }
        }
    }
    private var lastLayoutSize: CGSize = .zero
    private let cursorOutline = CAShapeLayer()
    private let cursorHighlight = CAShapeLayer()
    private var hoverPoint: CGPoint?
    private var contactPoint: CGPoint?
    private var contactPressure: CGFloat = 1
    private var contactAltitude: CGFloat = .pi / 2
    private var pencilTouch: UITouch?
    private var selectionTouch: UITouch?
    private var pickingTouch: UITouch?
    private var fingerTouches: [UITouch] = []
    private var panStartPoint: CGPoint = .zero
    private var panStartOffset: CGPoint = .zero
    private var transformStart: TwoFingerTransform?

    private var historyTap: HistoryTap?

    private struct HistoryTap {
        var started: TimeInterval
        var origins: [UITouch: CGPoint] = [:]
        var active: Set<UITouch> = []
        var peakTouches = 0
        var valid = true
        var zoom: CGFloat
        var rotation: CGFloat
        var pan: CGPoint
    }

    // The canvas owns three-finger history gestures instead of the system edit menu.
    override var editingInteractionConfiguration: UIEditingInteractionConfiguration { .none }

    private struct TwoFingerTransform {
        var distance: CGFloat
        var angle: CGFloat
        var zoom: CGFloat
        var rotation: CGFloat
        var canvasAnchor: CGPoint
    }

    override init(frame: CGRect, device: MTLDevice?) {
        super.init(frame: frame, device: device)
        isMultipleTouchEnabled = true
        cursorOutline.fillColor = UIColor.clear.cgColor
        cursorOutline.strokeColor = UIColor.black.cgColor
        cursorOutline.lineWidth = 2
        cursorHighlight.fillColor = UIColor.clear.cgColor
        cursorHighlight.strokeColor = UIColor.white.cgColor
        cursorHighlight.lineWidth = 1
        layer.addSublayer(cursorOutline)
        layer.addSublayer(cursorHighlight)
        let hover = UIHoverGestureRecognizer(target: self, action: #selector(pencilHover(_:)))
        hover.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.pencil.rawValue)]
        hover.cancelsTouchesInView = false
        addGestureRecognizer(hover)
        NotificationCenter.default.addObserver(self, selector: #selector(hideBrushCursor),
            name: UIApplication.willResignActiveNotification, object: nil)
    }

    required init(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layoutSubviews() {
        super.layoutSubviews()
        session?.renderer.fitIfNeeded(viewSize: bounds.size)
        refreshBrushCursor()
        // This MTKView draws on demand. UIKit can otherwise stretch the last
        // presented drawable to its new bounds until the next canvas gesture.
        if bounds.size != lastLayoutSize {
            lastLayoutSize = bounds.size
            setNeedsDisplay()
        }
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window == nil { hideBrushCursor() }
    }

    @objc private func pencilHover(_ gesture: UIHoverGestureRecognizer) {
        switch gesture.state {
        case .began, .changed:
            hoverPoint = gesture.location(in: self)
        default:
            hoverPoint = nil
        }
        refreshBrushCursor()
    }

    @objc private func hideBrushCursor() {
        if UIApplication.shared.applicationState != .active { historyTap = nil }
        hoverPoint = nil
        contactPoint = nil
        refreshBrushCursor()
    }

    /// Core Animation composites the cursor above Metal; it never enters page pixels.
    func refreshBrushCursor() {
        let position = contactPoint ?? hoverPoint
        let radius: CGFloat
        if let session, let position,
           !session.selectedTool.isRegionTool, session.selectedTool != .bucket,
           !session.activeModifiers.contains(.option), pickingTouch == nil,
           bounds.contains(position),
           session.renderer.isInsideCanvas(session.renderer.canvasPoint(from: position)) {
            let pressure = contactPoint != nil ? session.mappedPressure(contactPressure) : 1
            let fallback = CGFloat(session.brush.radius(pressure: pressure,
                altitude: contactPoint != nil ? Double(contactAltitude) : .pi / 2))
            let tipRadius = contactPoint != nil ? (session.renderer.previewTipRadius ?? fallback) : fallback
            radius = tipRadius * session.renderer.zoom
        } else {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            cursorOutline.isHidden = true
            cursorHighlight.isHidden = true
            CATransaction.commit()
            return
        }
        guard let position else { return }
        let path = UIBezierPath(ovalIn: CGRect(x: -radius, y: -radius,
                                               width: radius * 2, height: radius * 2)).cgPath
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for cursor in [cursorOutline, cursorHighlight] {
            cursor.contentsScale = contentScaleFactor
            cursor.path = path
            cursor.position = position
            cursor.isHidden = false
        }
        CATransaction.commit()
    }

    private func updateContactCursor(_ touch: UITouch) {
        hoverPoint = nil
        contactPoint = touch.preciseLocation(in: self)
        contactPressure = pressure(for: touch)
        contactAltitude = touch.altitudeAngle
        refreshBrushCursor()
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        super.touchesBegan(touches, with: event)
        trackHistoryTapBegan(touches)
        guard let session else { return }
        let optionDown = session.activeModifiers.contains(.option)
            || event?.modifierFlags.contains(.alternate) == true
        let shiftDown = session.activeModifiers.contains(.shift)
            || event?.modifierFlags.contains(.shift) == true
        let newFingers = touches.filter { $0.type == .direct }
        if selectionTouch == nil, pickingTouch == nil, pencilTouch == nil,
           newFingers.count >= 2 {
            fingerTouches.append(contentsOf: newFingers)
            beginFingerTransform()
            return
        }
        if selectionTouch == nil, pickingTouch == nil,
           session.selectedTool.isRegionTool,
           let pencil = touches.first(where: { $0.type == .pencil }) {
            selectionTouch = pencil
            hideBrushCursor()
            session.beginSelection(at: session.renderer.canvasPoint(from: pencil.preciseLocation(in: self)),
                                   shift: shiftDown, option: optionDown)
            return
        }
        if !session.selectedTool.isRegionTool, session.selectedTool != .bucket, pickingTouch == nil, optionDown,
           let pencil = touches.first(where: { $0.type == .pencil }) {
            pickingTouch = pencil
            hideBrushCursor()
            let point = session.renderer.canvasPoint(from: pencil.preciseLocation(in: self))
            session.pickColor(at: point)
            return
        }
        guard pickingTouch == nil, selectionTouch == nil else { return }
        if pencilTouch == nil, let pencil = touches.first(where: { $0.type == .pencil }) {
            pencilTouch = pencil
            fingerTouches.removeAll()
            transformStart = nil
            let point = session.renderer.canvasPoint(from: pencil.preciseLocation(in: self))
            session.beginStroke(at: point, pressure: pressure(for: pencil),
                    timestamp: pencil.timestamp, altitude: pencil.altitudeAngle,
                    azimuth: pencil.azimuthAngle(in: self))
            updateContactCursor(pencil)
            return
        }
        guard pencilTouch == nil else { return }
        for finger in touches where finger.type == .direct {
            fingerTouches.append(finger)
        }
        beginFingerTransform()
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        super.touchesMoved(touches, with: event)
        trackHistoryTapMovement(touches)
        guard let session else { return }
        if let selectionTouch, touches.contains(selectionTouch) {
            let samples = event?.coalescedTouches(for: selectionTouch) ?? [selectionTouch]
            session.updateSelection(along: samples.map {
                session.renderer.canvasPoint(from: $0.preciseLocation(in: self))
            })
            return
        }
        if let pickingTouch {
            if touches.contains(pickingTouch) {
                let point = session.renderer.canvasPoint(from: pickingTouch.preciseLocation(in: self))
                session.pickColor(at: point)
            }
            return
        }
        if let pencil = pencilTouch, touches.contains(pencil) {
            for sample in event?.coalescedTouches(for: pencil) ?? [pencil] {
                let point = session.renderer.canvasPoint(from: sample.preciseLocation(in: self))
                session.appendStroke(at: point, pressure: pressure(for: sample),
                    timestamp: sample.timestamp, altitude: sample.altitudeAngle,
                    azimuth: sample.azimuthAngle(in: self), renderPreview: false)
            }
            session.refreshStrokePreview()
            updateContactCursor(pencil)
        } else if pencilTouch == nil {
            updateFingerTransform()
        }
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        super.touchesEnded(touches, with: event)
        let historyAction = finishHistoryTapTouches(touches)
        // Finish the existing touch lifecycle before rebuilding history/selection.
        defer {
            if historyAction == 2 { session?.undo() }
            if historyAction == 3 { session?.redo() }
        }
        if let selectionTouch, touches.contains(selectionTouch) {
            if let session {
                session.endSelection(at: session.renderer.canvasPoint(
                    from: selectionTouch.preciseLocation(in: self)))
            }
            self.selectionTouch = nil
            return
        }
        if let pickingTouch, touches.contains(pickingTouch) {
            if let session {
                let point = session.renderer.canvasPoint(from: pickingTouch.preciseLocation(in: self))
                session.pickColor(at: point)
            }
            self.pickingTouch = nil
            return
        }
        if let pencil = pencilTouch, touches.contains(pencil), let session {
            let point = session.renderer.canvasPoint(from: pencil.preciseLocation(in: self))
            session.appendStroke(at: point, pressure: pressure(for: pencil),
                    timestamp: pencil.timestamp, altitude: pencil.altitudeAngle,
                    azimuth: pencil.azimuthAngle(in: self))
            session.endStroke()
            pencilTouch = nil
            contactPoint = nil
            refreshBrushCursor()
        }
        removeEndedFingers(touches)
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        super.touchesCancelled(touches, with: event)
        historyTap?.valid = false
        _ = finishHistoryTapTouches(touches)
        if let selectionTouch, touches.contains(selectionTouch) {
            session?.cancelSelection()
            self.selectionTouch = nil
            return
        }
        if let pickingTouch, touches.contains(pickingTouch) {
            self.pickingTouch = nil
            return
        }
        if let pencil = pencilTouch, touches.contains(pencil) {
            session?.cancelStroke()
            pencilTouch = nil
            hideBrushCursor()
        }
        removeEndedFingers(touches)
    }

    private func trackHistoryTapBegan(_ touches: Set<UITouch>) {
        if touches.contains(where: { $0.type == .pencil }) { historyTap?.valid = false }
        let fingers = touches.filter { $0.type == .direct }
        guard !fingers.isEmpty, let renderer = session?.renderer else { return }
        if historyTap == nil {
            historyTap = HistoryTap(started: fingers.map(\.timestamp).min() ?? 0,
                valid: pencilTouch == nil && selectionTouch?.type != .pencil && pickingTouch?.type != .pencil
                    && !touches.contains(where: { $0.type == .pencil }),
                zoom: renderer.zoom, rotation: renderer.rotation, pan: renderer.pan)
        }
        for finger in fingers {
            historyTap?.origins[finger] = finger.location(in: self)
            historyTap?.active.insert(finger)
        }
        guard var tap = historyTap else { return }
        tap.peakTouches = max(tap.peakTouches, tap.active.count)
        if tap.origins.count > 3 { tap.valid = false }
        historyTap = tap
    }

    private func trackHistoryTapMovement(_ touches: Set<UITouch>) {
        guard let tap = historyTap, tap.valid else { return }
        for touch in touches {
            guard let origin = tap.origins[touch] else { continue }
            let point = touch.location(in: self)
            if hypot(point.x - origin.x, point.y - origin.y) > 10 {
                historyTap?.valid = false
                return
            }
        }
    }

    private func finishHistoryTapTouches(_ touches: Set<UITouch>) -> Int? {
        trackHistoryTapMovement(touches)
        guard var tap = historyTap else { return nil }
        tap.active.subtract(touches)
        historyTap = tap
        guard tap.active.isEmpty else { return nil }
        historyTap = nil
        let ended = touches.map(\.timestamp).max() ?? tap.started
        let count = tap.origins.count
        guard tap.valid, (2...3).contains(count), tap.peakTouches == count,
              ended - tap.started <= 0.35 else { return nil }
        // Ignore tiny incidental motion during a tap, preserving the viewport.
        if let renderer = session?.renderer {
            renderer.zoom = tap.zoom
            renderer.rotation = tap.rotation
            renderer.pan = tap.pan
            setNeedsDisplay()
        }
        return count
    }

    private func pressure(for touch: UITouch) -> CGFloat {
        guard touch.type == .pencil, touch.maximumPossibleForce > 0 else { return 1 }
        return touch.force / touch.maximumPossibleForce
    }

    private func beginFingerTransform() {
        if !fingerTouches.isEmpty { hideBrushCursor() }
        guard let renderer = session?.renderer else { return }
        if fingerTouches.count >= 2 {
            let first = fingerTouches[0].location(in: self)
            let second = fingerTouches[1].location(in: self)
            let center = midpoint(first, second)
            transformStart = TwoFingerTransform(
                distance: max(1, hypot(second.x - first.x, second.y - first.y)),
                angle: atan2(second.y - first.y, second.x - first.x),
                zoom: renderer.zoom, rotation: renderer.rotation,
                canvasAnchor: renderer.canvasPoint(from: center))
        } else if let finger = fingerTouches.first {
            transformStart = nil
            panStartPoint = finger.location(in: self)
            panStartOffset = renderer.pan
        } else {
            transformStart = nil
        }
    }

    private func updateFingerTransform() {
        guard let renderer = session?.renderer else { return }
        if fingerTouches.count >= 2, let start = transformStart {
            let first = fingerTouches[0].location(in: self)
            let second = fingerTouches[1].location(in: self)
            let center = midpoint(first, second)
            let distance = hypot(second.x - first.x, second.y - first.y)
            let angle = atan2(second.y - first.y, second.x - first.x)
            renderer.zoom = min(8, max(renderer.minimumViewportZoom, start.zoom * distance / start.distance))
            renderer.rotation = start.rotation + angle - start.angle
            let mapped = renderer.rotatedScaledPoint(start.canvasAnchor)
            renderer.pan = CGPoint(x: center.x - mapped.x, y: center.y - mapped.y)
        } else if let finger = fingerTouches.first {
            let point = finger.location(in: self)
            renderer.pan = CGPoint(x: panStartOffset.x + point.x - panStartPoint.x,
                                   y: panStartOffset.y + point.y - panStartPoint.y)
        }
        refreshBrushCursor()
        setNeedsDisplay()
    }

    private func removeEndedFingers(_ touches: Set<UITouch>) {
        fingerTouches.removeAll { touches.contains($0) }
        beginFingerTransform()
    }

    private func midpoint(_ a: CGPoint, _ b: CGPoint) -> CGPoint {
        CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2)
    }
}
