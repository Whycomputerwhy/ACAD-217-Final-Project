import Foundation

@main
struct InteractionSessionChecks {
    static func main() {
        var state = InteractionSession()
        var starts = 0
        for index in 0..<10_000 {
            if state.update(target: "Catalog-apple", position: [Float(index), 1, 2]) { starts += 1 }
        }
        precondition(starts == 1, "Repeated updates must never create additional models")
        let original = state.active!.id
        precondition(state.active!.latest.x == 9_999)
        precondition(!state.update(target: "Catalog-elephant", position: [100, 200, 300]))
        precondition(state.active!.target == "Catalog-apple", "Gaze changes must not steal a drag")
        precondition(state.active!.latest.x == 9_999)
        precondition(state.accepts(original), "Loading during the same drag is valid")
        state.end()
        precondition(!state.accepts(original), "Late USDZ loads after release must not spawn")
        precondition(state.end() == nil, "Repeated end/cancel cleanup must be harmless")
        precondition(state.update(target: "Source-A", position: [3, 4, 5]))
        precondition(state.active!.id != original, "The next pinch must have a new identity")
        precondition(!state.accepts(original), "Old load completion must not affect a new pinch")
        let initialObject: SIMD3<Float> = [0.1, 0.2, 0.3]
        let first = state.active!
        precondition(initialObject + (first.latest - first.start) == initialObject, "Pickup preserves the grab offset")
        _ = state.update(target: "Source-A", position: [3.25, 4.5, 5.75])
        let moved = state.active!
        let position = initialObject + (moved.latest - moved.start)
        precondition(abs(position.x - 0.35) < 0.00001 && abs(position.y - 0.7) < 0.00001)
        state.end()
        print("PASS: 10,000 updates / one spawn; target ownership; release; cancellation; late-load rejection; pickup offset")
    }
}
