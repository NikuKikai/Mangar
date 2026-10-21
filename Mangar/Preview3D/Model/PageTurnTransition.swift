import Foundation

/// A page turn is scene motion, independent of UI animations and document edits.
struct PageTurnTransition {
    let start: Float
    let end: Float
    let startedAt: Double
    let duration: Double
    let destination: Int?

    init(start: Float, end: Float, startedAt: Double, destination: Int?) {
        self.start=start; self.end=end; self.startedAt=startedAt; self.destination=destination
        duration=max(0.14,0.34*Double(abs(end-start)))
    }
    func value(at time: Double) -> Float {
        let t=Float(min(1,max(0,(time-startedAt)/duration)))
        let eased=1-pow(1-t,3)
        return start+(end-start)*eased
    }
    func isComplete(at time: Double) -> Bool { time >= startedAt+duration }
}
