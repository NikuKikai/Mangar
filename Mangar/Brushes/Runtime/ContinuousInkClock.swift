import UIKit

/// Display time is input, never an implicit shader clock: recorded ink replays exactly.
@MainActor
final class ContinuousInkClock: NSObject {
    private final class Target: NSObject {
        weak var clock: ContinuousInkClock?
        init(_ clock: ContinuousInkClock) { self.clock = clock }
        @objc func tick(_ link: CADisplayLink) { clock?.onTick?(ProcessInfo.processInfo.systemUptime) }
    }
    private var link: CADisplayLink?
    var onTick: ((TimeInterval) -> Void)?
    func start() {
        stop()
        let link = CADisplayLink(target: Target(self), selector: #selector(Target.tick(_:)))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 30, maximum: 60, preferred: 60)
        link.add(to: .main, forMode: .common)
        self.link = link
    }
    func stop() { link?.invalidate(); link = nil }
    deinit { link?.invalidate() }
}
