import ARKit
import Observation
import RealityKit
import simd
import SwiftUI

@MainActor
@Observable
final class TossGameController {
    private enum FlightState {
        case waitingForUser
        case held
        case towardCharacter
        case beingCaught
        case returningToUser
    }

    private struct HandSample {
        let time: TimeInterval
        let position: SIMD3<Float>
    }

    private let session = ARKitSession()
    private let handTracking = HandTrackingProvider()
    private var handTask: Task<Void, Never>?
    private var updateSubscription: EventSubscription?

    private weak var sceneRoot: Entity?
    private var ball: ModelEntity?
    private var character: ModelEntity?
    private var ground: ModelEntity?
    private var state: FlightState = .waitingForUser
    private var heldChirality: HandAnchor.Chirality?
    private var handSamples: [HandSample] = []
    private var lastTrackedHandPosition = SIMD3<Float>(0, 1.15, -0.25)
    private var characterHome = SIMD3<Float>(0, 0.45, -1.65)
    private var lastResetToken = 0
    private var lastTestTossToken = 0

    private let ballRadius: Float = 0.08
    private let grabRadius: Float = 0.16
    private let pinchClosedDistance: Float = 0.035
    private let pinchOpenDistance: Float = 0.060
    private let catchRadius: Float = 0.52

    func configure(scene: Entity, content: RealityViewContent, model: AppModel) {
        guard ball == nil else { return }
        sceneRoot = scene

        let ground = (scene.findEntity(named: "Ground") as? ModelEntity) ?? makeGround()
        let character = (scene.findEntity(named: "Character") as? ModelEntity) ?? makeCharacter()
        let ball = (scene.findEntity(named: "Ball") as? ModelEntity) ?? makeBall()

        if ground.parent == nil { scene.addChild(ground) }
        if character.parent == nil { scene.addChild(character) }
        if ball.parent == nil { scene.addChild(ball) }

        self.ground = ground
        self.character = character
        self.ball = ball
        characterHome = character.position

        installPhysics(on: ground, character: character, ball: ball)
        updateSubscription = content.subscribe(to: SceneEvents.Update.self) { [weak self, weak model] event in
            guard let self, let model else { return }
            self.update(deltaTime: Float(event.deltaTime), model: model)
        }

        reset(model: model)
    }

    func startHandTracking(model: AppModel) {
        guard handTask == nil else { return }
        guard HandTrackingProvider.isSupported else {
            model.phase = .handTrackingUnavailable
            return
        }

        handTask = Task { [weak self, weak model] in
            guard let self, let model else { return }
            do {
                try await session.run([handTracking])
                for await update in handTracking.anchorUpdates {
                    guard !Task.isCancelled else { break }
                    processHand(update.anchor, model: model)
                }
            } catch {
                model.phase = .handTrackingDenied
            }
        }
    }

    func stop() {
        handTask?.cancel()
        handTask = nil
        updateSubscription?.cancel()
        updateSubscription = nil
        session.stop()
    }

    func consumeCommands(resetToken: Int, testTossToken: Int, model: AppModel) {
        if resetToken != lastResetToken {
            lastResetToken = resetToken
            reset(model: model)
        }
        if testTossToken != lastTestTossToken {
            lastTestTossToken = testTossToken
            launchTestToss(model: model)
        }
    }

    private func processHand(_ anchor: HandAnchor, model: AppModel) {
        guard anchor.isTracked,
              let skeleton = anchor.handSkeleton,
              let ball else { return }

        let thumb = skeleton.joint(.thumbTip)
        let index = skeleton.joint(.indexFingerTip)
        guard thumb.isTracked, index.isTracked else { return }

        let thumbPosition = worldPosition(anchor: anchor, joint: thumb)
        let indexPosition = worldPosition(anchor: anchor, joint: index)
        let pinchPosition = (thumbPosition + indexPosition) * 0.5
        let pinchDistance = simd_distance(thumbPosition, indexPosition)
        lastTrackedHandPosition = pinchPosition

        if state == .held {
            guard heldChirality == anchor.chirality else { return }
            if pinchDistance >= pinchOpenDistance {
                releaseBall(model: model)
            } else {
                ball.position = pinchPosition
                ball.orientation = simd_quatf(angle: 0, axis: [0, 1, 0])
                recordHandSample(pinchPosition)
            }
            return
        }

        let canGrab = state == .waitingForUser || state == .returningToUser
        if canGrab,
           pinchDistance <= pinchClosedDistance,
           simd_distance(ball.position(relativeTo: nil), pinchPosition) <= grabRadius {
            grabBall(with: anchor.chirality, at: pinchPosition, model: model)
        }
    }

    private func grabBall(with chirality: HandAnchor.Chirality,
                          at position: SIMD3<Float>,
                          model: AppModel) {
        guard let ball else { return }
        heldChirality = chirality
        state = .held
        handSamples.removeAll(keepingCapacity: true)
        setBallMode(.kinematic)
        ball.components.set(PhysicsMotionComponent())
        ball.setPosition(position, relativeTo: nil)
        recordHandSample(position)
        model.phase = .holding
    }

    private func releaseBall(model: AppModel) {
        guard let ball else { return }
        let velocity = estimatedReleaseVelocity()
        heldChirality = nil
        state = .towardCharacter
        setBallMode(.dynamic)
        ball.components.set(PhysicsMotionComponent(linearVelocity: velocity,
                                                   angularVelocity: [0, 8, 0]))
        handSamples.removeAll(keepingCapacity: true)
        model.phase = .flying
    }

    private func update(deltaTime: Float, model: AppModel) {
        guard let ball, let character else { return }

        if state == .towardCharacter {
            let catchPoint = character.position(relativeTo: nil) + SIMD3<Float>(0, 0.18, 0.18)
            if simd_distance(ball.position(relativeTo: nil), catchPoint) <= catchRadius {
                beginCatch(model: model)
            }
        }

        if ball.position(relativeTo: nil).y < -0.75, state != .beingCaught {
            // A miss stays unacknowledged; stop extreme falling so reset remains easy to use.
            setBallMode(.kinematic)
            ball.components.set(PhysicsMotionComponent())
        }

        _ = deltaTime
    }

    private func beginCatch(model: AppModel) {
        guard let ball, let character, state == .towardCharacter else { return }
        state = .beingCaught
        model.phase = .catching
        setBallMode(.kinematic)
        ball.components.set(PhysicsMotionComponent())

        let ballWorld = ball.position(relativeTo: nil)
        let characterWorld = character.position(relativeTo: nil)
        let lateralStep = max(-0.28, min(0.28, ballWorld.x - characterWorld.x))
        let depthStep = max(-0.16, min(0.16, ballWorld.z - characterWorld.z))
        var catchTransform = character.transform
        catchTransform.translation += SIMD3<Float>(lateralStep, 0, depthStep)
        character.move(to: catchTransform, relativeTo: character.parent,
                       duration: 0.18, timingFunction: .easeInOut)

        Task { [weak self, weak model] in
            try? await Task.sleep(for: .milliseconds(190))
            guard let self, let model, self.state == .beingCaught,
                  let ball = self.ball, let character = self.character else { return }
            ball.setPosition(character.position(relativeTo: nil) + SIMD3<Float>(0, 0.25, 0.18),
                             relativeTo: nil)
            try? await Task.sleep(for: .milliseconds(230))
            guard self.state == .beingCaught else { return }
            self.throwBack(model: model)
        }
    }

    private func throwBack(model: AppModel) {
        guard let ball, let character else { return }
        let origin = character.position(relativeTo: nil) + SIMD3<Float>(0, 0.25, 0.18)
        ball.setPosition(origin, relativeTo: nil)

        let target = lastTrackedHandPosition
        let flightTime: Float = 0.78
        var velocity = (target - origin) / flightTime
        velocity.y += 0.5 * 9.81 * flightTime
        velocity = clampMagnitude(velocity, maximum: 5.2)

        setBallMode(.dynamic)
        ball.components.set(PhysicsMotionComponent(linearVelocity: velocity,
                                                   angularVelocity: [0, -7, 0]))
        state = .returningToUser
        model.phase = .returning

        var homeTransform = character.transform
        homeTransform.translation = characterHome
        character.move(to: homeTransform, relativeTo: character.parent,
                       duration: 0.28, timingFunction: .easeInOut)
    }

    private func launchTestToss(model: AppModel) {
        guard let ball else { return }
        reset(model: model)
        ball.position = SIMD3<Float>(0.34, 1.05, -0.55)
        setBallMode(.dynamic)
        ball.components.set(PhysicsMotionComponent(linearVelocity: [-0.35, 1.25, -2.0],
                                                   angularVelocity: [0, 7, 0]))
        state = .towardCharacter
        model.phase = .flying
    }

    private func reset(model: AppModel) {
        guard let ball, let character else { return }
        state = .waitingForUser
        heldChirality = nil
        handSamples.removeAll(keepingCapacity: true)
        character.position = characterHome
        character.orientation = simd_quatf(angle: 0, axis: [0, 1, 0])
        ball.position = SIMD3<Float>(0, 1.05, -0.55)
        ball.orientation = simd_quatf(angle: 0, axis: [0, 1, 0])
        setBallMode(.dynamic)
        ball.components.set(PhysicsMotionComponent())
        model.phase = HandTrackingProvider.isSupported ? .ready : .handTrackingUnavailable
    }

    private func installPhysics(on ground: ModelEntity,
                                character: ModelEntity,
                                ball: ModelEntity) {
        // RCP-authored cubes carry their dimensions as transform scale, while the
        // procedural fallbacks have already baked dimensions into their meshes.
        let groundSize: SIMD3<Float> = ground.scale == .one ? [3.6, 0.06, 3.6] : .one
        let groundShape = ShapeResource.generateBox(size: groundSize)
        ground.components.set(CollisionComponent(shapes: [groundShape]))
        ground.components.set(PhysicsBodyComponent(shapes: [groundShape],
                                                   mass: 1,
                                                   material: .generate(friction: 0.82, restitution: 0.22),
                                                   mode: .static))

        let characterSize: SIMD3<Float> = character.scale == .one ? [0.56, 0.9, 0.44] : .one
        let characterShape = ShapeResource.generateBox(size: characterSize)
        character.components.set(CollisionComponent(shapes: [characterShape]))
        character.components.set(PhysicsBodyComponent(shapes: [characterShape],
                                                      mass: 30,
                                                      mode: .kinematic))

        let ballShape = ShapeResource.generateSphere(radius: ballRadius)
        ball.components.set(CollisionComponent(shapes: [ballShape]))
        ball.components.set(PhysicsBodyComponent(shapes: [ballShape],
                                                mass: 0.16,
                                                material: .generate(friction: 0.65, restitution: 0.64),
                                                mode: .dynamic))
    }

    private func setBallMode(_ mode: PhysicsBodyMode) {
        guard let ball else { return }
        let shape = ShapeResource.generateSphere(radius: ballRadius)
        ball.components.set(PhysicsBodyComponent(shapes: [shape],
                                                mass: 0.16,
                                                material: .generate(friction: 0.65, restitution: 0.64),
                                                mode: mode))
    }

    private func recordHandSample(_ position: SIMD3<Float>) {
        let now = ProcessInfo.processInfo.systemUptime
        handSamples.append(HandSample(time: now, position: position))
        handSamples.removeAll { now - $0.time > 0.12 }
    }

    private func estimatedReleaseVelocity() -> SIMD3<Float> {
        guard let first = handSamples.first, let last = handSamples.last else {
            return [0, 0.8, -1.4]
        }
        let duration = Float(last.time - first.time)
        guard duration > 0.018 else { return [0, 0.8, -1.4] }
        return clampMagnitude((last.position - first.position) / duration, maximum: 6.0)
    }

    private func worldPosition(anchor: HandAnchor,
                               joint: HandSkeleton.Joint) -> SIMD3<Float> {
        let transform = anchor.originFromAnchorTransform * joint.anchorFromJointTransform
        return SIMD3<Float>(transform.columns.3.x, transform.columns.3.y, transform.columns.3.z)
    }

    private func clampMagnitude(_ value: SIMD3<Float>, maximum: Float) -> SIMD3<Float> {
        let magnitude = simd_length(value)
        guard magnitude > maximum, magnitude > 0 else { return value }
        return value / magnitude * maximum
    }

    private func makeGround() -> ModelEntity {
        let material = SimpleMaterial(color: .init(white: 0.22, alpha: 1), roughness: 0.9, isMetallic: false)
        let entity = ModelEntity(mesh: .generateBox(size: [3.6, 0.06, 3.6]), materials: [material])
        entity.name = "Ground"
        entity.position = [0, -0.03, -1.0]
        return entity
    }

    private func makeCharacter() -> ModelEntity {
        let material = SimpleMaterial(color: .init(red: 0.28, green: 0.66, blue: 0.98, alpha: 1),
                                      roughness: 0.55,
                                      isMetallic: false)
        let entity = ModelEntity(mesh: .generateBox(size: [0.56, 0.9, 0.44]), materials: [material])
        entity.name = "Character"
        entity.position = [0, 0.45, -1.65]
        return entity
    }

    private func makeBall() -> ModelEntity {
        let material = SimpleMaterial(color: .init(red: 1.0, green: 0.34, blue: 0.12, alpha: 1),
                                      roughness: 0.38,
                                      isMetallic: false)
        let entity = ModelEntity(mesh: .generateSphere(radius: ballRadius), materials: [material])
        entity.name = "Ball"
        entity.position = [0, 1.05, -0.55]
        return entity
    }
}
