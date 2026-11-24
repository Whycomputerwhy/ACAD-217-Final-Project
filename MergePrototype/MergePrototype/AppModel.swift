import Foundation
import Observation

@MainActor
@Observable
final class AppModel {
    static let playSpaceID = "FusionStudio"

    enum HDRI: String, CaseIterable, Identifiable {
        case morning = "Morning"
        case night = "Night"
        case grass = "Grass"
        var id: String { rawValue }
        var resourceName: String {
            switch self {
            case .morning: "MorningSky"
            case .night: "NightSky"
            case .grass: "NoonGrass"
            }
        }
    }

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
    var addAssetToken = 0
    var assetToAdd = "apple"
    var catalogDragToken = 0
    var catalogDragAsset: String?
    var catalogDragIndex = 0
    var catalogDragLocation = SIMD3<Float>.zero
    var catalogDragStartLocation = SIMD3<Float>.zero
    var isCatalogDragging = false
    var fullScaleView = false
    var selectedHDRI: HDRI = .morning
    var inspectionEnabled = false
    var fusionCount = 0

    func addAsset(_ asset: String) {
        assetToAdd = asset
        addAssetToken += 1
    }

    func beginCatalogDrag(_ asset: String, index: Int, location: SIMD3<Float>) {
        guard !isCatalogDragging || catalogDragAsset != asset else { return }
        catalogDragAsset = asset
        catalogDragIndex = index
        catalogDragStartLocation = location
        catalogDragLocation = location
        isCatalogDragging = true
        catalogDragToken += 1
    }

    func updateCatalogDrag(location: SIMD3<Float>) {
        catalogDragLocation = location
    }

    func endCatalogDrag() {
        isCatalogDragging = false
    }
}

