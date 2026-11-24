import Foundation

/// A recognized system drag owns one target until release or cancellation.
/// Loading completion cannot start a new interaction or unlock the current one.
struct InteractionSession {
    struct Drag {
        let id: UUID
        let target: String
        let start: SIMD3<Float>
        var latest: SIMD3<Float>
    }

    private(set) var active: Drag?

    mutating func update(target: String, position: SIMD3<Float>) -> Bool {
        if var drag = active {
            guard drag.target == target else { return false }
            drag.latest = position
            active = drag
            return false
        }
        active = Drag(id: UUID(), target: target, start: position, latest: position)
        return true
    }

    func accepts(_ id: UUID) -> Bool { active?.id == id }

    @discardableResult
    mutating func end() -> Drag? {
        defer { active = nil }
        return active
    }
}
