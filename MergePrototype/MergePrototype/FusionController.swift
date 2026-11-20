import ARKit
import RealityKit
import SwiftUI

/// Owns the spatial workbench, plane placement, palette tiles, and fast visual-union preview.
@MainActor
final class FusionController {
    static let availableAssets = ["apple", "elephant", "crate", "chair", "table", "clock", "candlestick", "ukulele", "eraser", "pen"]
    private let workSurfaceHeight: Float = 0.001
    private let snapReleaseHeight: Float = 0.05
    private let root = Entity()
    private let workbench = Entity()
    private let previewRoot = Entity()
    private let paletteRoot = Entity()
    private let fullScaleRoot = Entity()
    private let fullScaleComposition = Entity()
    private let fullScaleGround = ModelEntity(
        mesh: .generatePlane(width: 14, depth: 14),
        materials: [SimpleMaterial(color: .init(white: 0.11, alpha: 1), isMetallic: false)]
    )
    private let session = ARKitSession()
    private let planeProvider = PlaneDetectionProvider(alignments: [.horizontal])

    private var sources: [Entity] = []
    private var activeDrag: DragState?
    private var activePlaneID: UUID?
    private var isFullScale = false
    private var fullScaleNeedsRebuild = false
    private var lastResetToken = -1
    private var lastAppleToken = 0
    private var lastElephantToken = 0
    private var lastCrateToken = 0
    private var lastUndoToken = 0
    private var lastClearToken = 0
    private var lastMakeWhiteToken = 0
    private var lastAddAssetToken = 0
    private var lastCatalogDragToken = 0
    private var catalogDragEntity: Entity?
    private var catalogDragAsset: String?
    private var catalogDragOrigin = SIMD3<Float>.zero
    private var objectPaletteAttached = false
    private var editPaletteAttached = false
    private var configured = false
    private var appModel: AppModel?

    func configure(content: RealityViewContent, model: AppModel) {
        guard !configured else { return }
        configured = true
        appModel = model
        root.name = "FusionRoot"
        workbench.name = "DetectedSquareWorkbench"
        workbench.position = [0, 0.72, -0.9] // Fallback until ARKit finds a surface.
        root.addChild(workbench)
        root.addChild(fullScaleRoot)
        fullScaleRoot.addChild(fullScaleComposition)
        fullScaleGround.position.y = -0.002
        fullScaleRoot.addChild(fullScaleGround)
        fullScaleRoot.isEnabled = false
        workbench.addChild(previewRoot)
        workbench.addChild(paletteRoot)
        makeWorkbench()
        content.add(root)
        reset(model: model)
        startPlaneDetection()
    }

    func attachObjectPalette(_ attachment: Entity?) {
        guard let attachment, !objectPaletteAttached else { return }
        objectPaletteAttached = true
        attachment.position = [-0.40, 0.20, 0]
        attachment.scale = SIMD3(repeating: 0.42)
        paletteRoot.addChild(attachment)
    }

    func attachEditPalette(_ attachment: Entity?) {
        guard let attachment, !editPaletteAttached else { return }
        editPaletteAttached = true
        attachment.position = [0.42, 0.20, 0]
        attachment.scale = SIMD3(repeating: 0.42)
        paletteRoot.addChild(attachment)
    }

    func consumeCommands(model: AppModel) {
        guard configured else { return }
        if model.resetToken != lastResetToken { reset(model: model) }
        if model.clearToken != lastClearToken { lastClearToken = model.clearToken; clearSources(model: model) }
        if model.undoToken != lastUndoToken { lastUndoToken = model.undoToken; removeLastSource(model: model) }
        if model.makeWhiteToken != lastMakeWhiteToken { lastMakeWhiteToken = model.makeWhiteToken; applyWhiteMaterial() }
        if model.addAssetToken != lastAddAssetToken { lastAddAssetToken = model.addAssetToken; addAsset(model.assetToAdd, at: nextPosition()) }
        consumeCatalogDrag(model: model)
        if model.addAppleToken != lastAppleToken { lastAppleToken = model.addAppleToken; addAsset("apple", at: nextPosition()) }
        if model.addElephantToken != lastElephantToken { lastElephantToken = model.addElephantToken; addAsset("elephant", at: nextPosition()) }
        if model.addCrateToken != lastCrateToken { lastCrateToken = model.addCrateToken; addAsset("crate", at: nextPosition()) }
        if isFullScale, fullScaleNeedsRebuild { rebuildFullScaleComposition() }
        refreshPreview(model: model)
    }

    func setFullScale(_ enabled: Bool) {
        guard enabled != isFullScale else { return }
        isFullScale = enabled
        if enabled {
            // The miniature editor stays on its detected tabletop; only the presentation clone moves away.
            fullScaleRoot.isEnabled = true
            fullScaleNeedsRebuild = true
            rebuildFullScaleComposition()
        } else {
            fullScaleRoot.isEnabled = false
        }
    }

    func drag(_ value: EntityTargetValue<DragGesture.Value>) {
        let position = value.convert(value.location3D, from: .local, to: workbench)
        if let source = sourceRoot(for: value.entity) {
            if activeDrag?.entity !== source {
                // Preserve the exact grab point when the system's pinch gesture begins.
                activeDrag = DragState(entity: source, offset: source.position - position)
            }
            source.position = snappedPosition(for: source, requested: position + (activeDrag?.offset ?? .zero))
        }
        if let appModel { refreshPreview(model: appModel) }
    }

    func finishDrag(_ value: EntityTargetValue<DragGesture.Value>, model: AppModel) {
        activeDrag = nil
        refreshPreview(model: model)
    }

    private func makeWorkbench() {
        let surface = ModelEntity(mesh: .generatePlane(width: 0.5, depth: 0.5), materials: [SimpleMaterial(color: .white, isMetallic: false)])
        surface.name = "WhiteGridSurface"
        surface.position.y = 0.0004 // Keep the overlay flush with the detected tabletop.
        surface.components.set(OpacityComponent(opacity: 0.08))
        workbench.addChild(surface)

        let gridMaterial = SimpleMaterial(color: .white, isMetallic: false)
        let divisions = 10
        let step: Float = 0.5 / Float(divisions)
        for index in 0...divisions {
            let offset = -0.25 + Float(index) * step
            let vertical = ModelEntity(mesh: .generateBox(size: [0.0012, 0.0005, 0.5]), materials: [gridMaterial])
            vertical.position = [offset, 0.00075, 0]
            vertical.components.set(OpacityComponent(opacity: index % 5 == 0 ? 0.78 : 0.46))
            workbench.addChild(vertical)

            let horizontal = ModelEntity(mesh: .generateBox(size: [0.5, 0.0005, 0.0012]), materials: [gridMaterial])
            horizontal.position = [0, 0.00075, offset]
            horizontal.components.set(OpacityComponent(opacity: index % 5 == 0 ? 0.78 : 0.46))
            workbench.addChild(horizontal)
        }
    }

    private func reset(model: AppModel) {
        clearSources(model: model)
        lastResetToken = model.resetToken
        lastAppleToken = model.addAppleToken
        lastElephantToken = model.addElephantToken
        lastCrateToken = model.addCrateToken
        lastUndoToken = model.undoToken
        lastClearToken = model.clearToken
        lastMakeWhiteToken = model.makeWhiteToken
        lastAddAssetToken = model.addAssetToken
        lastCatalogDragToken = model.catalogDragToken
        model.phase = .ready
    }

    private func clearSources(model: AppModel) {
        sources.forEach { $0.removeFromParent() }
        sources.removeAll()
        activeDrag = nil
        previewRoot.children.forEach { $0.removeFromParent() }
        model.fusionCount = 0
        fullScaleNeedsRebuild = true
    }

    private func removeLastSource(model: AppModel) {
        sources.popLast()?.removeFromParent()
        fullScaleNeedsRebuild = true
        refreshPreview(model: model)
    }

    private func applyWhiteMaterial() {
        let white = SimpleMaterial(color: .white, isMetallic: false)
        sources.forEach { replaceMaterials(in: $0, with: white) }
        fullScaleNeedsRebuild = true
    }

    private func replaceMaterials(in entity: Entity, with material: any RealityKit.Material) {
        if var model = entity.components[ModelComponent.self] {
            model.materials = Array(repeating: material, count: max(1, model.materials.count))
            entity.components.set(model)
        }
        entity.children.forEach { replaceMaterials(in: $0, with: material) }
    }

    private func nextPosition() -> SIMD3<Float> {
        SIMD3(-0.20 + Float(sources.count % 3) * 0.16, 0.12, -0.12 + Float(sources.count % 2) * 0.18)
    }

    private func addAsset(_ kind: String, at position: SIMD3<Float>) {
        Task {
            guard let loaded = await loadAsset(kind, desiredSize: 0.28) else { return }
            loaded.position = position
            loaded.name = "FusionSource-\(kind)-\(sources.count)"
            loaded.components.set(InputTargetComponent())
            loaded.components.set(HoverEffectComponent())
            loaded.generateCollisionShapes(recursive: true)
            workbench.addChild(loaded)
            loaded.position = snappedPosition(for: loaded, requested: loaded.position)
            sources.append(loaded)
            fullScaleNeedsRebuild = true
            if let appModel { refreshPreview(model: appModel) }
        }
    }

    /// SwiftUI's Model3D catalog supplies a 2D drag translation. This maps that
    /// translation onto the tabletop while the spawned RealityKit entity follows it.
    private func consumeCatalogDrag(model: AppModel) {
        if model.catalogDragToken != lastCatalogDragToken {
            lastCatalogDragToken = model.catalogDragToken
            beginCatalogDrag(asset: model.catalogDragAsset ?? "apple")
        }

        guard let entity = catalogDragEntity else { return }
        if model.isCatalogDragging {
            let translation = model.catalogDragTranslation
            var requested = catalogDragOrigin
            requested.x += Float(translation.width) * 0.0011
            requested.z -= Float(translation.height) * 0.0011
            entity.position = snappedPosition(for: entity, requested: requested)
            if let appModel { refreshPreview(model: appModel) }
        } else {
            catalogDragEntity = nil
            catalogDragAsset = nil
            fullScaleNeedsRebuild = true
        }
    }

    private func beginCatalogDrag(asset: String) {
        catalogDragEntity = nil
        catalogDragAsset = asset
        catalogDragOrigin = nextPosition()
        Task {
            guard let loaded = await loadAsset(asset, desiredSize: 0.28), catalogDragAsset == asset else { return }
            loaded.name = "FusionSource-\(asset)-\(sources.count)"
            loaded.components.set(InputTargetComponent())
            loaded.components.set(HoverEffectComponent())
            loaded.generateCollisionShapes(recursive: true)
            workbench.addChild(loaded)
            loaded.position = snappedPosition(for: loaded, requested: catalogDragOrigin)
            sources.append(loaded)
            catalogDragEntity = loaded
            if let appModel { refreshPreview(model: appModel) }
        }
    }

    private func loadAsset(_ kind: String, desiredSize: Float) async -> Entity? {
        guard let url = Bundle.main.url(forResource: kind, withExtension: "usdz"), let loaded = try? await Entity(contentsOf: url) else { return nil }
        let bounds = loaded.visualBounds(relativeTo: nil)
        let extent = max(bounds.extents.x, max(bounds.extents.y, bounds.extents.z))
        loaded.scale = SIMD3(repeating: max(0.001, desiredSize / extent))
        return loaded
    }

    /// Snap only while the visual bottom is within 5 cm of the grid; otherwise allow a free-air move.
    private func snappedPosition(for entity: Entity, requested: SIMD3<Float>) -> SIMD3<Float> {
        let bounds = entity.visualBounds(relativeTo: workbench)
        let bottomOffset = bounds.min.y - entity.position.y
        let requestedBottom = requested.y + bottomOffset
        guard requestedBottom <= workSurfaceHeight + snapReleaseHeight else { return requested }
        var snapped = requested
        snapped.y = workSurfaceHeight - bottomOffset
        return snapped
    }

    private func sourceRoot(for entity: Entity) -> Entity? {
        var candidate: Entity? = entity
        while let current = candidate {
            if sources.contains(where: { $0 === current }) { return current }
            candidate = current.parent
        }
        return nil
    }

    private func refreshPreview(model: AppModel) {
        var connections = 0
        for first in sources.indices {
            for second in sources.indices where second > first {
                let a = sources[first].position(relativeTo: workbench)
                let b = sources[second].position(relativeTo: workbench)
                let distance = simd_distance(a, b)
                guard distance < 0.34 else { continue }
                connections += 1
            }
        }
        model.fusionCount = connections
        model.phase = model.inspectionEnabled ? .inspecting : (connections > 0 ? .fusing : .isolated)
    }

    private func rebuildFullScaleComposition() {
        fullScaleComposition.children.forEach { $0.removeFromParent() }
        fullScaleComposition.position = .zero
        let fullScaleFactor: Float = 8
        for source in sources {
            let clone = source.clone(recursive: true)
            clone.position = source.position(relativeTo: workbench) * fullScaleFactor
            clone.orientation = source.orientation(relativeTo: workbench)
            clone.scale = clone.scale * SIMD3(repeating: fullScaleFactor)
            fullScaleComposition.addChild(clone)
        }

        fullScaleRoot.position = [0, 0, -6.0]

        if !sources.isEmpty {
            let bounds = fullScaleComposition.visualBounds(relativeTo: fullScaleRoot)
            fullScaleComposition.position.y -= bounds.min.y
        }
        fullScaleNeedsRebuild = false
    }

    private func startPlaneDetection() {
        guard PlaneDetectionProvider.isSupported else { return }
        Task {
            let authorization = await session.requestAuthorization(for: PlaneDetectionProvider.requiredAuthorizations)
            guard authorization[.worldSensing] == .allowed else { return }
            do {
                try await session.run([planeProvider])
                for await update in planeProvider.anchorUpdates {
                    guard update.event != .removed,
                          update.anchor.classification == .table || update.anchor.classification == .floor else { continue }
                    if !isFullScale && (activePlaneID == nil || activePlaneID == update.anchor.id) {
                        activePlaneID = update.anchor.id
                        workbench.transform = Transform(matrix: update.anchor.originFromAnchorTransform)
                    }
                }
            } catch { }
        }
    }

    private struct DragState {
        let entity: Entity
        let offset: SIMD3<Float>
    }
}
