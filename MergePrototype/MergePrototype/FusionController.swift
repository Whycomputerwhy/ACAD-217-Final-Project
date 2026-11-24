import ARKit
import ImageIO
import RealityKit
import SwiftUI

/// Only explicitly tagged card / source roots participate in the studio drag.
struct StudioInputTarget: Component {}

@MainActor
final class FusionController {
    static let availableAssets = ["apple", "elephant", "crate", "chair", "table", "clock", "candlestick", "ukulele", "eraser", "pen"]
    private let workSurfaceHeight: Float = 0.001
    private let snapReleaseHeight: Float = 0.05
    private let fullScaleFactor: Float = 12
    private let root = Entity()
    private let workbench = Entity()
    private let paletteRoot = Entity()
    private let fullScaleRoot = Entity()
    private let fullScaleComposition = Entity()
    private let fullScaleSky = ModelEntity()
    // Lighting must outlive the full-scale visual root, which is disabled in mixed mode.
    private let environmentLight = Entity()
    private let session = ARKitSession()
    private let planeProvider = PlaneDetectionProvider(alignments: [.horizontal])

    private var sources: [Entity] = []
    private var templates: [String: Entity] = [:]
    private var templateLoads: [String: Task<Entity?, Never>] = [:]
    private var warmupTasks: [Task<Void, Never>] = []
    private var planeTask: Task<Void, Never>?
    private var interaction = InteractionSession()
    private var draggedEntity: Entity?
    private var objectStart = SIMD3<Float>.zero
    private var usesHandPose = false
    private var sceneRevision = UUID()
    private var attachedCards: Set<String> = []
    private var headerAttached = false
    private var editAttached = false
    private var placementLocked = false
    private var configured = false
    private var isFullScale = false
    private var appModel: AppModel?
    private var lastReset = -1
    private var lastUndo = 0
    private var lastClear = 0
    private var lastWhite = 0
    private var lastAdd = 0
    private var lastApple = 0
    private var lastElephant = 0
    private var lastCrate = 0
    private var fullScaleClones: [ObjectIdentifier: Entity] = [:]
    private struct EnvironmentPreset {
        let texture: TextureResource
        let lighting: EnvironmentResource
    }
    private var environments: [AppModel.HDRI: EnvironmentPreset] = [:]
    private var environmentTask: Task<Void, Never>?
    private var requestedHDRI: AppModel.HDRI?
    private var environmentRequest = UUID()
    private var hasEnvironment = false

    func configure(content: RealityViewContent, model: AppModel) {
        guard !configured else { return }
        configured = true
        appModel = model
        StudioInputTarget.registerComponent()
        workbench.name = "Workbench"
        workbench.position = [0, 0.72, -0.9]
        root.addChild(workbench)
        root.addChild(fullScaleRoot)
        root.addChild(environmentLight)
        workbench.addChild(paletteRoot)
        fullScaleRoot.addChild(fullScaleComposition)
        fullScaleRoot.addChild(fullScaleSky)
        fullScaleRoot.position = [0, 0, -3.6]
        fullScaleComposition.position.y = -workSurfaceHeight * fullScaleFactor
        fullScaleRoot.isEnabled = false
        fullScaleSky.name = "HDRISky"
        fullScaleSky.components.set(ModelSortGroupComponent(group: .planarUIAlwaysBehind, order: -100))
        makeWorkbench()
        content.add(root)
        consumeCommands(model: model)
        startPlaneDetection()
        if model.fullScaleView { setFullScale(true) }

        // Templates have one canonical size. Two lanes warm the cache; a user
        // request for an in-flight model shares that same task.
        warmupTasks = (0..<2).map { lane in
            Task { @MainActor in
                for index in stride(from: lane, to: Self.availableAssets.count, by: 2) {
                    guard !Task.isCancelled else { return }
                    _ = await template(for: Self.availableAssets[index])
                }
            }
        }
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--verify-studio") {
            Task { @MainActor in await runDiagnostics() }
        }
        #endif
    }

    func attachHeader(_ attachment: Entity?) {
        guard let attachment, !headerAttached else { return }
        headerAttached = true
        attachment.position = [-0.36, 0.385, 0.06]
        attachment.scale = SIMD3(repeating: 0.65)
        paletteRoot.addChild(attachment)
    }

    func attachEditPalette(_ attachment: Entity?) {
        guard let attachment, !editAttached else { return }
        editAttached = true
        attachment.position = [0.34, 0.18, 0.06]
        attachment.scale = SIMD3(repeating: 0.48)
        paletteRoot.addChild(attachment)
    }

    func attachCatalogCard(_ attachment: Entity?, asset: String, index: Int) {
        guard let attachment, !attachedCards.contains(asset) else { return }
        attachment.scale = SIMD3(repeating: 0.65)
        let card = ModelEntity(
            mesh: .generateBox(size: [0.074, 0.068, 0.003], cornerRadius: 0.006),
            materials: [UnlitMaterial(color: .init(white: 0.10, alpha: 1))]
        )
        card.name = "Catalog-\(asset)"
        card.position = [-0.40 + Float(index % 2) * 0.08, 0.32 - Float(index / 2) * 0.075, 0.06]
        card.addChild(attachment)
        attachment.position.z = 0.003
        // Each attachment has its own target. No estimates of rows in a large panel,
        // no overlapping boxes, and no second SwiftUI gesture on the same card.
        card.components.set(CollisionComponent(shapes: [.generateBox(size: [0.074, 0.068, 0.008])]))
        enableInput(on: card)
        paletteRoot.addChild(card)
        attachedCards.insert(asset)
    }

    func consumeCommands(model: AppModel) {
        guard configured else { return }
        if model.resetToken != lastReset {
            lastReset = model.resetToken
            clearSources()
        }
        if model.clearToken != lastClear { lastClear = model.clearToken; clearSources() }
        if model.undoToken != lastUndo {
            lastUndo = model.undoToken
            endInteraction()
            sources.popLast()?.removeFromParent()
            rebuildFullScaleComposition()
            refreshState()
        }
        if model.makeWhiteToken != lastWhite {
            lastWhite = model.makeWhiteToken
            let material = SimpleMaterial(color: .white, isMetallic: false)
            sources.forEach { replaceMaterials(in: $0, with: material) }
            rebuildFullScaleComposition()
        }
        if model.addAssetToken != lastAdd { lastAdd = model.addAssetToken; addAsset(model.assetToAdd) }
        if model.addAppleToken != lastApple { lastApple = model.addAppleToken; addAsset("apple") }
        if model.addElephantToken != lastElephant { lastElephant = model.addElephantToken; addAsset("elephant") }
        if model.addCrateToken != lastCrate { lastCrate = model.addCrateToken; addAsset("crate") }
        if isFullScale, requestedHDRI != model.selectedHDRI { loadHDRI(model.selectedHDRI) }
        // Do not write observable UI state on every RealityView update.
    }

    func drag(_ value: EntityTargetValue<DragGesture.Value>) {
        let target = value.entity
        guard target.components.has(StudioInputTarget.self) else { return }
        if let active = interaction.active, active.target != target.name { return }
        let asset = target.name.hasPrefix("Catalog-") ? String(target.name.dropFirst(8)) : nil
        if interaction.active == nil {
            usesHandPose = asset != nil && value.inputDevicePose3D != nil
        }
        let point: SIMD3<Float>
        if usesHandPose {
            guard let pose = value.inputDevicePose3D else { return }
            point = value.convert(pose.position, from: .local, to: workbench)
        } else {
            point = value.convert(value.location3D, from: .local, to: workbench)
        }
        let didBegin = interaction.update(target: target.name, position: point)
        guard let drag = interaction.active else { return }
        if didBegin {
            if let asset {
                let id = drag.id
                Task { @MainActor in
                    guard let template = await template(for: asset), interaction.accepts(id) else { return }
                    // This task is launched once per gesture, not once per loading interval.
                    let entity = template.clone(recursive: true)
                    entity.name = "Source-\(UUID().uuidString)"
                    guard let current = interaction.active else { return }
                    entity.position = current.latest
                    workbench.addChild(entity)
                    sources.append(entity)
                    draggedEntity = entity
                    objectStart = current.start
                    updateLighting()
                    updateDraggedEntity()
                    rebuildFullScaleComposition()
                    refreshState()
                }
            } else if sources.contains(where: { $0 === target }) {
                draggedEntity = target
                objectStart = target.position
            }
        }
        updateDraggedEntity()
    }

    func finishDrag(_ value: EntityTargetValue<DragGesture.Value>) {
        // Consume the last event before dropping the captured target.
        if let active = interaction.active, active.target == value.entity.name {
            let point = usesHandPose ? value.inputDevicePose3D?.position : value.location3D
            if let point {
                _ = interaction.update(target: active.target, position: value.convert(point, from: .local, to: workbench))
                updateDraggedEntity()
            }
        }
        endInteraction()
    }

    func endInteraction() {
        guard interaction.end() != nil else { return }
        if let entity = draggedEntity, entity.parent != nil {
            entity.position = snappedPosition(for: entity, requested: entity.position)
            enableInput(on: entity)
            syncFullScaleTransform(for: entity)
        }
        draggedEntity = nil
        usesHandPose = false
        refreshState()
    }

    private func updateDraggedEntity() {
        guard let drag = interaction.active, let entity = draggedEntity else { return }
        let position = objectStart + (drag.latest - drag.start)
        entity.position = snappedPosition(for: entity, requested: position)
        syncFullScaleTransform(for: entity)
    }

    private func template(for asset: String) async -> Entity? {
        if let template = templates[asset] { return template }
        if let pending = templateLoads[asset] { return await pending.value }
        let task = Task { @MainActor () -> Entity? in
            let started = ContinuousClock.now
            do {
                guard let url = Bundle.main.url(forResource: asset, withExtension: "usdz") else { return nil }
                let geometry = try await Entity(contentsOf: url)
                removeRuntimeComponents(from: geometry)
                let wrapper = Entity()
                let normalizer = Entity()
                wrapper.addChild(normalizer)
                normalizer.addChild(geometry)
                let bounds = geometry.visualBounds(relativeTo: wrapper)
                let longest = max(bounds.extents.x, max(bounds.extents.y, bounds.extents.z))
                guard longest.isFinite, longest > 0 else { return nil }
                let scale: Float = 0.28 / longest
                // Geometry alone is scaled. The interactive root is ALWAYS scale 1.
                normalizer.scale = SIMD3(repeating: scale)
                normalizer.position = -bounds.center * scale
                let size = simd_max(bounds.extents * scale, SIMD3(repeating: 0.012))
                wrapper.components.set(CollisionComponent(shapes: [.generateBox(size: size)]))
                templates[asset] = wrapper
                #if DEBUG
                print("[MergePrototype] template \(asset) ready in \(started.duration(to: .now))")
                #endif
                return wrapper
            } catch {
                print("[MergePrototype] model \(asset) failed: \(error)")
                return nil
            }
        }
        templateLoads[asset] = task
        let result = await task.value
        templateLoads[asset] = nil
        return result
    }

    private func addAsset(_ asset: String) {
        let revision = sceneRevision
        Task { @MainActor in
            guard let template = await template(for: asset), sceneRevision == revision else { return }
            let entity = template.clone(recursive: true)
            entity.name = "Source-\(UUID().uuidString)"
            workbench.addChild(entity)
            entity.position = snappedPosition(for: entity, requested: [0, 0.001, 0])
            enableInput(on: entity)
            sources.append(entity)
            updateLighting()
            rebuildFullScaleComposition()
            refreshState()
        }
    }

    private func enableInput(on entity: Entity) {
        entity.components.set(StudioInputTarget())
        entity.components.set(InputTargetComponent())
        var highlight = HoverEffectComponent.HighlightHoverEffectStyle.default
        highlight.strength = 0.35
        entity.components.set(HoverEffectComponent(.highlight(highlight)))
    }

    private func removeRuntimeComponents(from entity: Entity) {
        entity.components.remove(StudioInputTarget.self)
        entity.components.remove(InputTargetComponent.self)
        entity.components.remove(HoverEffectComponent.self)
        entity.components.remove(CollisionComponent.self)
        entity.components.remove(PhysicsBodyComponent.self)
        entity.components.remove(PhysicsMotionComponent.self)
        entity.components.remove(ImageBasedLightReceiverComponent.self)
        if #available(visionOS 26.0, *) { entity.components.remove(ManipulationComponent.self) }
        for child in entity.children { removeRuntimeComponents(from: child) }
    }

    private func clearSources() {
        sceneRevision = UUID()
        endInteraction()
        sources.forEach { $0.removeFromParent() }
        sources.removeAll()
        rebuildFullScaleComposition()
        refreshState()
    }

    private func snappedPosition(for entity: Entity, requested: SIMD3<Float>) -> SIMD3<Float> {
        let bounds = entity.visualBounds(relativeTo: entity)
        let bottom = bounds.min.y * entity.scale.y
        guard requested.y + bottom <= workSurfaceHeight + snapReleaseHeight else { return requested }
        var result = requested
        result.y = workSurfaceHeight - bottom
        return result
    }

    private func makeWorkbench() {
        let material = SimpleMaterial(color: .white, isMetallic: false)
        for index in 0...10 {
            let offset = -Float(0.25) + Float(index) * 0.05
            for vertical in [true, false] {
                let line = ModelEntity(mesh: .generateBox(size: vertical ? [0.0012, 0.0005, 0.5] : [0.5, 0.0005, 0.0012]), materials: [material])
                line.position = vertical ? [offset, 0.00075, 0] : [0, 0.00075, offset]
                line.components.set(OpacityComponent(opacity: index % 5 == 0 ? 0.78 : 0.46))
                workbench.addChild(line)
            }
        }
    }

    private func replaceMaterials(in entity: Entity, with material: any RealityKit.Material) {
        if var model = entity.components[ModelComponent.self] {
            model.materials = Array(repeating: material, count: max(1, model.materials.count))
            entity.components.set(model)
        }
        for child in entity.children { replaceMaterials(in: child, with: material) }
    }

    private func refreshState() {
        guard let model = appModel else { return }
        var count = 0
        for a in sources.indices {
            for b in sources.indices where b > a {
                if simd_distance(sources[a].position, sources[b].position) < 0.34 { count += 1 }
            }
        }
        if model.fusionCount != count { model.fusionCount = count }
        let phase: AppModel.Phase = sources.isEmpty ? .ready : (count > 0 ? .fusing : .isolated)
        if model.phase != phase { model.phase = phase }
    }

    func setFullScale(_ enabled: Bool) {
        guard configured, enabled != isFullScale else { return }
        endInteraction()
        isFullScale = enabled
        fullScaleRoot.isEnabled = enabled
        updateLighting()
        if enabled {
            rebuildFullScaleComposition()
            loadHDRI(appModel?.selectedHDRI ?? .morning)
        }
    }

    private func rebuildFullScaleComposition() {
        fullScaleComposition.children.forEach { $0.removeFromParent() }
        fullScaleClones.removeAll()
        guard isFullScale else { return }
        for source in sources {
            let clone = source.clone(recursive: true)
            // Presentation copies must never steal gaze, pinch, or drag input.
            removeRuntimeComponents(from: clone)
            applyFullScaleTransform(from: source, to: clone)
            fullScaleComposition.addChild(clone)
            fullScaleClones[ObjectIdentifier(source)] = clone
        }
        updateLighting()
    }

    private func syncFullScaleTransform(for source: Entity) {
        guard isFullScale, let clone = fullScaleClones[ObjectIdentifier(source)] else { return }
        applyFullScaleTransform(from: source, to: clone)
    }

    private func applyFullScaleTransform(from source: Entity, to clone: Entity) {
        clone.position = source.position * fullScaleFactor
        clone.orientation = source.orientation
        clone.scale = source.scale * SIMD3(repeating: fullScaleFactor)
    }

    private func updateLighting() {
        applyLighting(to: workbench, enabled: isFullScale && hasEnvironment)
        applyLighting(to: fullScaleComposition, enabled: isFullScale && hasEnvironment)
    }

    private func applyLighting(to entity: Entity, enabled: Bool) {
        if entity.components.has(ModelComponent.self), enabled {
            entity.components.set(ImageBasedLightReceiverComponent(imageBasedLight: environmentLight))
        } else {
            entity.components.remove(ImageBasedLightReceiverComponent.self)
        }
        for child in entity.children { applyLighting(to: child, enabled: enabled) }
    }

    private func loadHDRI(_ hdri: AppModel.HDRI) {
        requestedHDRI = hdri
        environmentRequest = UUID()
        let request = environmentRequest
        environmentTask?.cancel()
        environmentTask = Task { @MainActor in
            do {
                let preset: EnvironmentPreset
                if let cached = environments[hdri] { preset = cached }
                else {
                    guard let url = Bundle.main.url(forResource: hdri.resourceName, withExtension: "exr", subdirectory: "\(hdri.resourceName).skybox") else {
                        throw CocoaError(.fileNoSuchFile)
                    }
                    let texture = try await TextureResource(contentsOf: url, withName: hdri.resourceName, options: .init(semantic: .hdrColor))
                    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                          let image = CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldAllowFloat: true] as CFDictionary) else {
                        throw CocoaError(.fileReadCorruptFile)
                    }
                    let cube = try await TextureResource(cubeFromEquirectangular: image, named: "\(hdri.resourceName)-light", quality: .normal, faceSize: 512, options: .init(semantic: .hdrColor))
                    let lighting = try await EnvironmentResource(cube: cube, options: .init())
                    preset = EnvironmentPreset(texture: texture, lighting: lighting)
                    environments[hdri] = preset
                }
                guard environmentRequest == request, !Task.isCancelled else { return }
                environmentLight.components.set(ImageBasedLightComponent(source: .single(preset.lighting), intensityExponent: 1))
                hasEnvironment = true
                var material = UnlitMaterial(texture: preset.texture)
                material.faceCulling = .front
                fullScaleSky.model = ModelComponent(mesh: .generateSphere(radius: 60), materials: [material])
                updateLighting()
            } catch {
                print("[MergePrototype] HDRI \(hdri.resourceName) failed: \(error)")
                // Keep RealityKit's default illumination if no HDRI has loaded.
            }
        }
    }

    private func startPlaneDetection() {
        guard PlaneDetectionProvider.isSupported else { return }
        planeTask = Task { @MainActor in
            let authorization = await session.requestAuthorization(for: PlaneDetectionProvider.requiredAuthorizations)
            guard authorization[.worldSensing] == .allowed else { return }
            do {
                try await session.run([planeProvider])
                for await update in planeProvider.anchorUpdates {
                    guard !Task.isCancelled else { return }
                    guard update.event != .removed, update.anchor.classification == .table,
                          !isFullScale, !placementLocked, interaction.active == nil, sources.isEmpty else { continue }
                    let plane = update.anchor.originFromAnchorTransform.columns.3
                    workbench.transform = Transform(translation: [plane.x, plane.y + 0.002, plane.z - 0.10])
                    placementLocked = true
                }
            } catch { print("[MergePrototype] plane tracking: \(error)") }
        }
    }

    func stop() {
        endInteraction()
        planeTask?.cancel()
        environmentTask?.cancel()
        warmupTasks.forEach { $0.cancel() }
        templateLoads.values.forEach { $0.cancel() }
        session.stop()
    }

    #if DEBUG
    /// Run in the simulator with --verify-studio. Exercises real USDZ / EXR resources.
    private func runDiagnostics() async {
        for asset in Self.availableAssets {
            guard let value = await template(for: asset) else {
                assertionFailure("Missing template: \(asset)"); return
            }
            let bounds = value.visualBounds(relativeTo: value)
            let longest = max(bounds.extents.x, max(bounds.extents.y, bounds.extents.z))
            precondition(abs(longest - 0.28) < 0.001, "Incorrect model size: \(asset) \(longest)")
            precondition(simd_length(bounds.center) < 0.001, "Off-center geometry: \(asset)")
            precondition(value.scale == .one, "Interactive root must be meter-scale")
            precondition(value.components.has(CollisionComponent.self), "Missing root collision")
            precondition(!value.components.has(InputTargetComponent.self), "Cached model must not receive input")
            let started = ContinuousClock.now
            for _ in 0..<100 { _ = value.clone(recursive: true) }
            print("[StudioChecks] \(asset): size=\(longest)m, 100 clones=\(started.duration(to: .now))")
        }
        if let value = templates["apple"] {
            let sample = value.clone(recursive: true)
            sample.name = "Source-diagnostic"
            workbench.addChild(sample)
            sample.position = snappedPosition(for: sample, requested: [0, 0, 0])
            sources.append(sample)
            enableInput(on: sample)
            setFullScale(true)
            for hdri in AppModel.HDRI.allCases {
                loadHDRI(hdri)
                await environmentTask?.value
                precondition(environments[hdri] != nil, "HDRI failed: \(hdri.resourceName)")
                precondition(environmentLight.isEnabledInHierarchy, "IBL must be enabled")
                precondition(hasReceiver(in: sample), "Workbench model must receive HDRI")
                precondition(!hasInput(in: fullScaleComposition), "Full-scale copies must never capture gestures")
                print("[StudioChecks] HDRI \(hdri.resourceName): sky + lighting + model receiver PASS")
            }
            setFullScale(false)
            precondition(!hasReceiver(in: sample), "Mixed mode must restore default lighting")
            clearSources()
        }
        print("[StudioChecks] ALL RESOURCE / SCALE / COLLISION / LIGHTING CHECKS PASSED")
    }

    private func hasReceiver(in entity: Entity) -> Bool {
        entity.components.has(ImageBasedLightReceiverComponent.self) || entity.children.contains { hasReceiver(in: $0) }
    }

    private func hasInput(in entity: Entity) -> Bool {
        entity.components.has(InputTargetComponent.self) || entity.components.has(CollisionComponent.self)
            || entity.children.contains { hasInput(in: $0) }
    }
    #endif
}
