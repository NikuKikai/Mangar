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
        uiView.session = session
        uiView.setNeedsDisplay()
    }
}

final class CanvasSurface: MTKView {
    weak var session: EditorSession?
    private var pencilTouch: UITouch?
    private var selectionTouch: UITouch?
    private var pickingTouch: UITouch?
    private var fingerTouches: [UITouch] = []
    private var panStartPoint: CGPoint = .zero
    private var panStartOffset: CGPoint = .zero
    private var transformStart: TwoFingerTransform?

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
    }

    required init(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layoutSubviews() {
        super.layoutSubviews()
        session?.renderer.fitIfNeeded(viewSize: bounds.size)
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        super.touchesBegan(touches, with: event)
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
        if let selectionTouch, selectionTouch.type == .direct,
           let secondFinger = touches.first(where: { $0.type == .direct }) {
            session.cancelSelection()
            fingerTouches = [selectionTouch, secondFinger]
            self.selectionTouch = nil
            beginFingerTransform()
            return
        }
        if selectionTouch == nil, pickingTouch == nil,
           session.selectedTool == .selection,
           let pencil = touches.first(where: { $0.type == .pencil }) {
            selectionTouch = pencil
            session.beginSelection(at: session.renderer.canvasPoint(from: pencil.preciseLocation(in: self)),
                                   shift: shiftDown, option: optionDown)
            return
        }
        if session.selectedTool != .selection, pickingTouch == nil, optionDown,
           let pencil = touches.first(where: { $0.type == .pencil }) {
            pickingTouch = pencil
            let point = session.renderer.canvasPoint(from: pencil.preciseLocation(in: self))
            session.pickColor(at: point)
            return
        }
        if let pickingTouch, pickingTouch.type == .direct,
           let secondFinger = touches.first(where: { $0.type == .direct }) {
            fingerTouches = [pickingTouch, secondFinger]
            self.pickingTouch = nil
            beginFingerTransform()
            return
        }
        guard pickingTouch == nil, selectionTouch == nil else { return }
        if pencilTouch == nil, let pencil = touches.first(where: { $0.type == .pencil }) {
            pencilTouch = pencil
            fingerTouches.removeAll()
            transformStart = nil
            let point = session.renderer.canvasPoint(from: pencil.preciseLocation(in: self))
            session.beginStroke(at: point, pressure: pressure(for: pencil))
            return
        }
        guard pencilTouch == nil else { return }
        if session.selectedTool == .selection, fingerTouches.isEmpty,
           let finger = touches.first(where: { $0.type == .direct }) {
            selectionTouch = finger
            session.beginSelection(at: session.renderer.canvasPoint(from: finger.preciseLocation(in: self)),
                                   shift: shiftDown, option: optionDown)
            return
        }
        if optionDown, fingerTouches.isEmpty,
           let finger = touches.first(where: { $0.type == .direct }) {
            pickingTouch = finger
            let point = session.renderer.canvasPoint(from: finger.preciseLocation(in: self))
            session.pickColor(at: point)
            return
        }
        for finger in touches where finger.type == .direct {
            fingerTouches.append(finger)
        }
        beginFingerTransform()
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        super.touchesMoved(touches, with: event)
        guard let session else { return }
        if let selectionTouch, touches.contains(selectionTouch) {
            session.updateSelection(to: session.renderer.canvasPoint(
                from: selectionTouch.preciseLocation(in: self)))
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
                session.appendStroke(at: point, pressure: pressure(for: sample))
            }
        } else if pencilTouch == nil {
            updateFingerTransform()
        }
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        super.touchesEnded(touches, with: event)
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
            session.appendStroke(at: point, pressure: pressure(for: pencil))
            session.endStroke()
            pencilTouch = nil
        }
        removeEndedFingers(touches)
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        super.touchesCancelled(touches, with: event)
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
        }
        removeEndedFingers(touches)
    }

    private func pressure(for touch: UITouch) -> CGFloat {
        guard touch.type == .pencil, touch.maximumPossibleForce > 0 else { return 1 }
        return touch.force / touch.maximumPossibleForce
    }

    private func beginFingerTransform() {
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
            renderer.zoom = min(8, max(0.05, start.zoom * distance / start.distance))
            renderer.rotation = start.rotation + angle - start.angle
            let mapped = renderer.rotatedScaledPoint(start.canvasAnchor)
            renderer.pan = CGPoint(x: center.x - mapped.x, y: center.y - mapped.y)
        } else if let finger = fingerTouches.first {
            let point = finger.location(in: self)
            renderer.pan = CGPoint(x: panStartOffset.x + point.x - panStartPoint.x,
                                   y: panStartOffset.y + point.y - panStartPoint.y)
        }
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
