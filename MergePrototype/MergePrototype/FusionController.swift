import ARKit
import RealityKit
import SwiftUI

/// Owns the spatial workbench, plane placement, palette tiles, and fast visual-union preview.
@MainActor
final class FusionController {
    private let root = Entity()
    private let workbench = Entity()
    private let previewRoot = Entity()
    private let paletteRoot = Entity()
    private let session = ARKitSession()
    private let planeProvider = PlaneDetectionProvider(alignments: [.horizontal])

    private var sources: [Entity] = []
    private var paletteSpawned: [String: Entity] = [:]
    private var palettePositions: [String: SIMD3<Float>] = [:]
    private var activePlaneID: UUID?
    private var lastResetToken = -1
    private var lastAppleToken = 0
    private var lastElephantToken = 0
    private var lastCrateToken = 0
    private var lastUndoToken = 0
    private var lastClearToken = 0
    private var paletteAttached = false
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

    func attachPalette(_ attachment: Entity?) {
        guard let attachment, !paletteAttached else { return }
        paletteAttached = true
        attachment.position = [0.78, 0.42, 0]
        attachment.scale = SIMD3(repeating: 0.42)
        paletteRoot.addChild(attachment)
    }

    func consumeCommands(model: AppModel) {
        guard configured else { return }
        if model.resetToken != lastResetToken { reset(model: model) }
        if model.clearToken != lastClearToken { lastClearToken = model.clearToken; clearSources(model: model) }
        if model.undoToken != lastUndoToken { lastUndoToken = model.undoToken; removeLastSource(model: model) }
        if model.addAppleToken != lastAppleToken { lastAppleToken = model.addAppleToken; addAsset("apple", at: nextPosition()) }
        if model.addElephantToken != lastElephantToken { lastElephantToken = model.addElephantToken; addAsset("elephant", at: nextPosition()) }
        if model.addCrateToken != lastCrateToken { lastCrateToken = model.addCrateToken; addAsset("crate", at: nextPosition()) }
        refreshPreview(model: model)
    }

    func drag(_ value: EntityTargetValue<DragGesture.Value>) {
        let position = value.convert(value.location3D, from: .local, to: workbench)
        if let kind = paletteKind(for: value.entity) {
            palettePositions[kind] = position
            if let source = paletteSpawned[kind] { source.position = position }
            else { addAsset(kind, at: position, paletteKind: kind) }
        } else if let source = sourceRoot(for: value.entity) {
            source.position = position
        }
        if let appModel { refreshPreview(model: appModel) }
    }

    func finishDrag(_ value: EntityTargetValue<DragGesture.Value>, model: AppModel) {
        if let kind = paletteKind(for: value.entity) { paletteSpawned[kind] = nil }
        refreshPreview(model: model)
    }

    private func makeWorkbench() {
        let base = ModelEntity(mesh: .generateBox(size: [1.18, 0.026, 1.18], cornerRadius: 0.035), materials: [SimpleMaterial(color: .init(white: 0.12, alpha: 0.96), isMetallic: true)])
        base.name = "SquareWorkbenchSurface"
        base.position = [0, 0.013, 0]
        workbench.addChild(base)
        let edge = ModelEntity(mesh: .generateBox(size: [1.22, 0.012, 1.22], cornerRadius: 0.045), materials: [SimpleMaterial(color: .init(red: 0.12, green: 0.95, blue: 0.72, alpha: 1), isMetallic: true)])
        edge.position = [0, -0.008, 0]
        edge.components.set(OpacityComponent(opacity: 0.45))
        workbench.addChild(edge)
        ["apple", "elephant", "crate"].enumerated().forEach { index, kind in Task { await makePaletteTile(kind: kind, index: index) } }
    }

    private func makePaletteTile(kind: String, index: Int) async {
        guard let tile = await loadAsset(kind, desiredSize: 0.095) else { return }
        tile.name = "PaletteTile-\(kind)"
        tile.position = [0.77, 0.13, 0.22 - Float(index) * 0.18]
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
        addAsset("apple", at: [-0.24, 0.16, -0.1])
        addAsset("elephant", at: [0.20, 0.16, -0.12])
        addAsset("crate", at: [0.00, 0.15, 0.14])
        model.phase = .ready
    }

    private func clearSources(model: AppModel) {
        sources.forEach { $0.removeFromParent() }
        sources.removeAll()
        paletteSpawned.removeAll()
        previewRoot.children.forEach { $0.removeFromParent() }
        model.fusionCount = 0
    }

    private func removeLastSource(model: AppModel) {
        sources.popLast()?.removeFromParent()
        refreshPreview(model: model)
    }

    private func nextPosition() -> SIMD3<Float> {
        SIMD3(-0.20 + Float(sources.count % 3) * 0.16, 0.16, -0.12 + Float(sources.count % 2) * 0.18)
    }

    private func addAsset(_ kind: String, at position: SIMD3<Float>, paletteKind: String? = nil) {
        Task {
            guard let loaded = await loadAsset(kind, desiredSize: 0.28) else { return }
            loaded.position = paletteKind.flatMap { palettePositions[$0] } ?? position
            loaded.name = "FusionSource-\(kind)-\(sources.count)"
            loaded.components.set(InputTargetComponent())
            loaded.components.set(HoverEffectComponent())
            loaded.generateCollisionShapes(recursive: true)
            workbench.addChild(loaded)
            sources.append(loaded)
            if let paletteKind { paletteSpawned[paletteKind] = loaded }
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
        previewRoot.children.forEach { $0.removeFromParent() }
        var connections = 0
        for first in sources.indices {
            for second in sources.indices where second > first {
                let a = sources[first].position(relativeTo: workbench)
                let b = sources[second].position(relativeTo: workbench)
                let distance = simd_distance(a, b)
                guard distance < 0.34 else { continue }
                connections += 1
                previewRoot.addChild(makeMeltBridge(between: a, and: b, distance: distance))
            }
        }
        model.fusionCount = connections
        model.phase = model.inspectionEnabled ? .inspecting : (connections > 0 ? .fusing : .isolated)
    }

    /// A deliberately narrow, metaball-inspired seam. It communicates live fusion while preserving the source forms.
    private func makeMeltBridge(between a: SIMD3<Float>, and b: SIMD3<Float>, distance: Float) -> Entity {
        let delta = b - a
        let axis = distance > 0.001 ? simd_normalize(delta) : SIMD3<Float>(0, 1, 0)
        let fusion = 1 - min(distance / 0.34, 1)
        let ripple = sin(Float(Date().timeIntervalSinceReferenceDate) * 7 + distance * 19) * 0.006
        let radius = max(0.026, 0.032 + fusion * 0.052 + ripple)
        let material = SimpleMaterial(color: .init(red: 0.16, green: 0.84, blue: 0.67, alpha: 1), isMetallic: true)
        let bridge = Entity()
        bridge.name = "LiveMeltBridge"

        let core = ModelEntity(mesh: .generateCylinder(height: max(0.045, distance), radius: radius), materials: [material])
        core.position = (a + b) * 0.5
        core.orientation = simd_quatf(from: SIMD3<Float>(0, 1, 0), to: axis)
        core.components.set(OpacityComponent(opacity: 0.72))
        bridge.addChild(core)

        // Rounded end bulbs make the seam read as soft material rather than a rigid connector.
        for point in [a + delta * 0.32, a + delta * 0.68] {
            let bulb = ModelEntity(mesh: .generateSphere(radius: radius * 1.28), materials: [material])
            bulb.position = point
            bulb.components.set(OpacityComponent(opacity: 0.66))
            bridge.addChild(bulb)
        }
        return bridge
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
