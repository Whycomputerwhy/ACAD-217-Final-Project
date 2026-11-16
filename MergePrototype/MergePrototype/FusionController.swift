import ARKit
import RealityKit
import SwiftUI

/// Owns the spatial workbench, plane placement, palette tiles, and fast visual-union preview.
@MainActor
final class FusionController {
    private let workSurfaceHeight: Float = 0.001
    private let root = Entity()
    private let workbench = Entity()
    private let previewRoot = Entity()
    private let paletteRoot = Entity()
    private let session = ARKitSession()
    private let planeProvider = PlaneDetectionProvider(alignments: [.horizontal])

    private var sources: [Entity] = []
    private var paletteSpawned: [String: Entity] = [:]
    private var palettePositions: [String: SIMD3<Float>] = [:]
    private var pendingPaletteSpawns: Set<String> = []
    private var activePlaneID: UUID?
    private var lastResetToken = -1
    private var lastAppleToken = 0
    private var lastElephantToken = 0
    private var lastCrateToken = 0
    private var lastUndoToken = 0
    private var lastClearToken = 0
    private var lastMakeWhiteToken = 0
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
        if model.addAppleToken != lastAppleToken { lastAppleToken = model.addAppleToken; addAsset("apple", at: nextPosition()) }
        if model.addElephantToken != lastElephantToken { lastElephantToken = model.addElephantToken; addAsset("elephant", at: nextPosition()) }
        if model.addCrateToken != lastCrateToken { lastCrateToken = model.addCrateToken; addAsset("crate", at: nextPosition()) }
        refreshPreview(model: model)
    }

    func drag(_ value: EntityTargetValue<DragGesture.Value>) {
        let position = value.convert(value.location3D, from: .local, to: workbench)
        if let kind = paletteKind(for: value.entity) {
            palettePositions[kind] = position
            if let source = paletteSpawned[kind] {
                source.position = snappedPosition(for: source, requested: position)
            } else if !pendingPaletteSpawns.contains(kind) {
                pendingPaletteSpawns.insert(kind)
                addAsset(kind, at: position, paletteKind: kind)
            }
        } else if let source = sourceRoot(for: value.entity) {
            source.position = snappedPosition(for: source, requested: position)
        }
        if let appModel { refreshPreview(model: appModel) }
    }

    func finishDrag(_ value: EntityTargetValue<DragGesture.Value>, model: AppModel) {
        if let kind = paletteKind(for: value.entity) { paletteSpawned[kind] = nil }
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
        ["apple", "elephant", "crate"].enumerated().forEach { index, kind in Task { await makePaletteTile(kind: kind, index: index) } }
    }

    private func makePaletteTile(kind: String, index: Int) async {
        guard let tile = await loadAsset(kind, desiredSize: 0.095) else { return }
        tile.name = "PaletteTile-\(kind)"
        tile.position = [-0.38, 0.08, 0.17 - Float(index) * 0.15]
        tile.components.set(InputTargetComponent())
        tile.components.set(HoverEffectComponent())
        tile.generateCollisionShapes(recursive: true)
        paletteRoot.addChild(tile)
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
        model.phase = .ready
    }

    private func clearSources(model: AppModel) {
        sources.forEach { $0.removeFromParent() }
        sources.removeAll()
        paletteSpawned.removeAll()
        pendingPaletteSpawns.removeAll()
        previewRoot.children.forEach { $0.removeFromParent() }
        model.fusionCount = 0
    }

    private func removeLastSource(model: AppModel) {
        sources.popLast()?.removeFromParent()
        refreshPreview(model: model)
    }

    private func applyWhiteMaterial() {
        let white = SimpleMaterial(color: .white, isMetallic: false)
        sources.forEach { replaceMaterials(in: $0, with: white) }
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

    private func addAsset(_ kind: String, at position: SIMD3<Float>, paletteKind: String? = nil) {
        Task {
            guard let loaded = await loadAsset(kind, desiredSize: 0.28) else {
                if let paletteKind { pendingPaletteSpawns.remove(paletteKind) }
                return
            }
            loaded.position = paletteKind.flatMap { palettePositions[$0] } ?? position
            loaded.name = "FusionSource-\(kind)-\(sources.count)"
            loaded.components.set(InputTargetComponent())
            loaded.components.set(HoverEffectComponent())
            loaded.generateCollisionShapes(recursive: true)
            workbench.addChild(loaded)
            loaded.position = snappedPosition(for: loaded, requested: loaded.position)
            sources.append(loaded)
            if let paletteKind {
                pendingPaletteSpawns.remove(paletteKind)
                paletteSpawned[paletteKind] = loaded
            }
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

    /// Align the visual bottom of an arbitrary USDZ asset to the near-zero-thickness grid plane.
    private func snappedPosition(for entity: Entity, requested: SIMD3<Float>) -> SIMD3<Float> {
        let bounds = entity.visualBounds(relativeTo: workbench)
        let bottomOffset = bounds.min.y - entity.position.y
        var snapped = requested
        snapped.y = workSurfaceHeight - bottomOffset
        return snapped
    }

    private func paletteKind(for entity: Entity) -> String? {
        var candidate: Entity? = entity
        while let current = candidate {
            if current.name.hasPrefix("PaletteTile-") {
                return String(current.name.dropFirst("PaletteTile-".count))
            }
            candidate = current.parent
        }
        return nil
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
                    if activePlaneID == nil || activePlaneID == update.anchor.id {
                        activePlaneID = update.anchor.id
                        workbench.transform = Transform(matrix: update.anchor.originFromAnchorTransform)
                    }
                }
            } catch { }
        }
    }
}
