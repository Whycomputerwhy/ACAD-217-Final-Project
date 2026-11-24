import ARKit
import ImageIO
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
    private let fullScaleFactor: Float = 12
    private let fullScaleSky = ModelEntity()
    private let session = ARKitSession()
    private let planeProvider = PlaneDetectionProvider(alignments: [.horizontal])

    private var sources: [Entity] = []
    private var assetTemplates: [String: Entity] = [:]
    private var activeDrag: DragState?
    private var activePlaneID: UUID?
    private var hasLockedWorkbenchPlacement = false
    private var isFullScale = false
    private var fullScaleNeedsRebuild = false
    private var loadedHDRI: AppModel.HDRI?
    private var fullScaleClones: [ObjectIdentifier: Entity] = [:]
    private var lastResetToken = -1
    private var lastAppleToken = 0
    private var lastElephantToken = 0
    private var lastCrateToken = 0
    private var lastUndoToken = 0
    private var lastClearToken = 0
    private var lastMakeWhiteToken = 0
    private var lastAddAssetToken = 0
    private var lastSelectedAssetToken = 0
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
        fullScaleSky.name = "HDRISky"
        fullScaleSky.components.set(
            ModelSortGroupComponent(group: .planarUIAlwaysBehind, order: -100)
        )
        fullScaleRoot.addChild(fullScaleSky)
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
        attachment.position = [-0.32, 0.15, 0.02]
        attachment.scale = SIMD3(repeating: 0.42)
        paletteRoot.addChild(attachment)
    }

    func attachEditPalette(_ attachment: Entity?) {
        guard let attachment, !editPaletteAttached else { return }
        editPaletteAttached = true
        attachment.position = [0.32, 0.15, 0.02]
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
        if model.selectedAssetToken != lastSelectedAssetToken {
            lastSelectedAssetToken = model.selectedAssetToken
            if let asset = model.selectedAsset { prefetchAsset(asset) }
        }
        if model.addAppleToken != lastAppleToken { lastAppleToken = model.addAppleToken; addAsset("apple", at: nextPosition()) }
        if model.addElephantToken != lastElephantToken { lastElephantToken = model.addElephantToken; addAsset("elephant", at: nextPosition()) }
        if model.addCrateToken != lastCrateToken { lastCrateToken = model.addCrateToken; addAsset("crate", at: nextPosition()) }
        if model.fullScaleView, loadedHDRI != model.selectedHDRI { loadHDRI(model.selectedHDRI) }
        if isFullScale, fullScaleNeedsRebuild { rebuildFullScaleComposition() }
        refreshPreview(model: model)
    }

    func setFullScale(_ enabled: Bool) {
        guard enabled != isFullScale else { return }
        isFullScale = enabled
        if enabled {
            // The miniature editor stays on its detected tabletop; only the presentation clone moves away.
            fullScaleRoot.isEnabled = true
            loadHDRI(appModel?.selectedHDRI ?? .morning)
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
            syncFullScaleTransform(for: source)
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
        surface.components.set(InputTargetComponent())
        surface.components.set(CollisionComponent(shapes: [.generateBox(size: [0.5, 0.008, 0.5])]))
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
        lastSelectedAssetToken = model.selectedAssetToken
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
            loaded.components.set(CollisionComponent(shapes: [.generateBox(size: [0.30, 0.30, 0.30])]))
            workbench.addChild(loaded)
            loaded.position = snappedPosition(for: loaded, requested: loaded.position)
            sources.append(loaded)
            fullScaleNeedsRebuild = true
            if isFullScale { addImageBasedLightReceiver(to: loaded) }
            enableManipulation(on: loaded)
            if let appModel { refreshPreview(model: appModel) }
        }
    }

    private func enableManipulation(on entity: Entity) {
        entity.components.set(InputTargetComponent())
        entity.components.set(subtleHoverEffect())
    }

    private func loadAsset(_ kind: String, desiredSize: Float) async -> Entity? {
        if let template = assetTemplates[kind] {
            return template.clone(recursive: true)
        }
        guard let url = Bundle.main.url(forResource: kind, withExtension: "usdz"), let loaded = try? await Entity(contentsOf: url) else { return nil }
        let bounds = loaded.visualBounds(relativeTo: nil)
        let extent = max(bounds.extents.x, max(bounds.extents.y, bounds.extents.z))
        loaded.scale = SIMD3(repeating: max(0.001, desiredSize / extent))
        assetTemplates[kind] = loaded
        return loaded.clone(recursive: true)
    }

    private func prefetchAsset(_ kind: String) {
        guard assetTemplates[kind] == nil else { return }
        Task { _ = await loadAsset(kind, desiredSize: 0.28) }
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

    func placeSelectedAsset(at value: EntityTargetValue<SpatialTapGesture.Value>, model: AppModel) {
        guard let asset = model.selectedAsset, isWorkbenchSurface(value.entity) else { return }
        let position = value.convert(value.location3D, from: .local, to: workbench)
        model.selectedAsset = nil
        addAsset(asset, at: position)
    }

    private func isWorkbenchSurface(_ entity: Entity) -> Bool {
        var candidate: Entity? = entity
        while let current = candidate {
            if current.name == "WhiteGridSurface" { return true }
            candidate = current.parent
        }
        return false
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
        fullScaleClones.removeAll()
        fullScaleComposition.position = .zero
        for source in sources {
            let clone = source.clone(recursive: true)
            applyFullScaleTransform(from: source, to: clone)
            addImageBasedLightReceiver(to: clone)
            fullScaleComposition.addChild(clone)
            fullScaleClones[ObjectIdentifier(source)] = clone
        }

        fullScaleRoot.position = [0, 0, -3.6]

        if !sources.isEmpty {
            let bounds = fullScaleComposition.visualBounds(relativeTo: fullScaleRoot)
            fullScaleComposition.position.y -= bounds.min.y
        }
        fullScaleNeedsRebuild = false
    }

    private func syncFullScaleTransform(for source: Entity) {
        guard isFullScale, let clone = fullScaleClones[ObjectIdentifier(source)] else { return }
        applyFullScaleTransform(from: source, to: clone)
    }

    private func applyFullScaleTransform(from source: Entity, to clone: Entity) {
        clone.position = source.position(relativeTo: workbench) * fullScaleFactor
        clone.orientation = source.orientation(relativeTo: workbench)
        clone.scale = source.scale * SIMD3(repeating: fullScaleFactor)
    }

    private func loadHDRI(_ hdri: AppModel.HDRI) {
        loadedHDRI = hdri
        Task {
            guard loadedHDRI == hdri else { return }

            guard let url = Bundle.main.url(
                forResource: hdri.resourceName,
                withExtension: "exr",
                subdirectory: "\(hdri.resourceName).skybox"
            ), let texture = try? await TextureResource(
                contentsOf: url,
                withName: hdri.resourceName,
                options: .init(semantic: .hdrColor)
            ) else {
                print("Unable to load HDRI sky texture: \(hdri.resourceName)")
                return
            }
            guard loadedHDRI == hdri else { return }

            // Build the IBL from this exact EXR rather than relying on a separate
            // bundle lookup. This guarantees the visible sky and model lighting match.
            if let imageSource = CGImageSourceCreateWithURL(url as CFURL, nil),
               let image = CGImageSourceCreateImageAtIndex(imageSource, 0, nil),
               let cube = try? await TextureResource(
                    cubeFromEquirectangular: image,
                    named: "\(hdri.resourceName)-cube",
                    quality: .normal,
                    faceSize: 512,
                    options: .init(semantic: .hdrColor)
               ), let environment = try? await EnvironmentResource(
                    cube: cube,
                    options: .init()
               ) {
                fullScaleRoot.components.set(
                    ImageBasedLightComponent(source: .single(environment), intensityExponent: 2.0)
                )
                addImageBasedLightReceiver(to: fullScaleComposition)
                addImageBasedLightReceiver(to: workbench)
            } else {
                print("Unable to build HDRI lighting: \(hdri.resourceName)")
            }

            var skyMaterial = UnlitMaterial(texture: texture)
            // Draw only the inside of the sphere and keep all SwiftUI attachments readable.
            skyMaterial.faceCulling = .front
            fullScaleSky.model = ModelComponent(
                mesh: .generateSphere(radius: 60),
                materials: [skyMaterial]
            )
        }
    }

    private func addImageBasedLightReceiver(to entity: Entity) {
        entity.components.set(ImageBasedLightReceiverComponent(imageBasedLight: fullScaleRoot))
        entity.children.forEach { addImageBasedLightReceiver(to: $0) }
    }

    private func subtleHoverEffect() -> HoverEffectComponent {
        var style = HoverEffectComponent.HighlightHoverEffectStyle.default
        style.strength = 0.35
        return HoverEffectComponent(.highlight(style))
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
                          update.anchor.classification == .table,
                          !isFullScale,
                          !hasLockedWorkbenchPlacement else { continue }

                    // A classified table is substantially more reliable than a floor
                    // for a 0.5 m editing surface. Keep the fallback centered in front
                    // of the viewer until one is confirmed, then lock it in place.
                    let anchorTransform = Transform(matrix: update.anchor.originFromAnchorTransform)
                    // Plane-anchor axes are arbitrary around the vertical normal. Use
                    // only its location, so menus retain their upright world orientation.
                    workbench.transform = Transform(
                        scale: .one,
                        rotation: .init(),
                        translation: anchorTransform.translation + SIMD3<Float>(0, 0.002, -0.10)
                    )
                    activePlaneID = update.anchor.id
                    hasLockedWorkbenchPlacement = true
                }
            } catch { }
        }
    }

    private struct DragState {
        let entity: Entity
        let offset: SIMD3<Float>
    }
}
