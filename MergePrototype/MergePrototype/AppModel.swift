import Foundation
import Observation

@MainActor
@Observable
final class AppModel {
    static let playSpaceID = "FusionStudio"

    enum Phase: String {
        case ready = "Place two forms close together to begin fusing"
        case isolated = "Move a form near another to preview the union"
        case fusing = "Live fusion preview — release to keep the composition"
        case inspecting = "Interior preview — the final shell will have a unified lining"
    }

    var phase: Phase = .ready
    var isImmersive = false
    var resetToken = 0
    var addAppleToken = 0
    var addElephantToken = 0
    var addCrateToken = 0
    var undoToken = 0
    var clearToken = 0
    var makeWhiteToken = 0
    var fullScaleView = false
    var inspectionEnabled = false
    var fusionCount = 0
}

