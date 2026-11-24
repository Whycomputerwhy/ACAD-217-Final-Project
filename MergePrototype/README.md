# MergePrototype — developer handoff

Updated: 2026-11-24

visionOS tabletop composition prototype. Ten bundled USDZ assets can be arranged on a 0.5 × 0.5 m white grid. Full-scale view presents a live 12× copy 3.6 m ahead, surrounded by one of three EXR panoramas. There is currently **no Boolean union, hollow shell, or export mesh**.

## Interaction

The left catalog uses individually placed SwiftUI Model3D cards. Each card has one visible RealityKit backing plate and one exact, non-overlapping collision target. The SwiftUI card is display-only; a single targeted system DragGesture owns all catalog and source manipulation. There are no hand-distance thresholds, low-level SpatialEventGesture handlers, invisible estimated grid overlays, or timed re-grab delays.

Dragging a card starts one InteractionSession. It requests at most one clone for the entire gesture. If the system supplies a hand pose, that pose is converted through EntityTargetValue into workbench meters. Otherwise the simulator's normal 3D gesture location is used. A new instance has no input target until release. Gaze changes cannot change the session's target.

Releasing or cancelling clears the session. A model that finishes loading after its creating gesture has ended is discarded rather than appearing unexpectedly. Existing objects preserve their original grab offset. Their visual bottoms snap within 5 cm of the grid. Changing immersion mode, clearing, undoing, or leaving the view also ends the current interaction.

The right SwiftUI panel retains Make White, Undo (delete last), Clear, Full-scale view, and Morning / Night / Grass HDRI choices. It remains beside the grid.

## Assets and collisions

Every cached template has a scale-1 interaction root and a separate centered geometry child normalized to 0.28 m maximum extent. The root owns one fitted box collision. Do not place a fixed 0.30 m collision box on an arbitrarily scaled imported USDZ root: its effective world size can be enormous or tiny.

Each asset has one shared in-flight load task. Two startup warmup lanes prepare the templates without convex-mesh collision generation; concurrent requests for the same asset share the same task. A card preview and a workbench instance must never share a cache entry normalized for different target sizes.

Imported input, collision, hover, physics, manipulation, and image-light receiver components are stripped from the geometry. Authored visual materials remain intact. Full-scale presentation clones are also stripped of all interaction components, so they cannot capture pinch or gaze targeting.

## Lighting

HDRI images are copied inside MorningSky.skybox, NightSky.skybox, and NoonGrass.skybox. They are loaded explicitly from the bundled EXR URLs. The equirectangular image is used both for an inward-facing unlit sky sphere and for generated HDR cubemap lighting.

The IBL source is a separate, enabled entity under the scene root. It is not under the full-scale root that is disabled in mixed mode. Only entities with actual ModelComponents receive explicit HDRI lighting, and only when full-scale mode and a valid HDRI are active. Returning to mixed mode removes those receiver overrides and restores system environment lighting. There is no artificial floor plane covering the panorama.

## Files

- MergePrototype/ImmersiveView.swift — cards, control attachment, one targeted gesture, GestureState cancellation cleanup.
- MergePrototype/InteractionSession.swift — framework-independent gesture identity and exclusive target ownership.
- MergePrototype/FusionController.swift — canonical template loading, fitted collisions, drag transforms, plane placement, full-scale copies, HDRI.
- MergePrototype/AppModel.swift — observable scene/UI state and edit commands.
- MergePrototype/MergePrototypeApp.swift — required bootstrap window and mixed/full ImmersiveSpace.
- Tests/InteractionSessionChecks.swift — repeat-event, target-switch, release, late-load, cancellation, and pickup-offset regression checks.
- Packages/RealityKitContent — retained Reality Composer Pro package.
- TossGameController.swift — excluded legacy file; do not reactivate.

## Verification

Open MergePrototype.xcodeproj and run the MergePrototype scheme.

Run the framework-independent regression checks from this directory:

```sh
swiftc -o /tmp/merge-session-checks MergePrototype/InteractionSession.swift Tests/InteractionSessionChecks.swift
/tmp/merge-session-checks
```

In a Debug build, launch with --verify-studio to run bundled-resource checks in the simulator. It checks all ten normalized USDZ templates, reports clone timings, loads all three HDRI lighting resources, checks IBL receiver wiring, ensures full-scale copies cannot receive input, and verifies lighting overrides are removed in mixed mode. Results are printed with [StudioChecks].

These checks verify state and resource correctness. They do not substitute for headset pinch/release testing. Do not describe a successful compilation as proof that interaction feels correct.

## Plane placement

A classified table supplies world position and height once. Its arbitrary local rotation is not copied to the UI. Placement is frozen while manipulating or after objects exist. Without a detected table, the fallback is [0, 0.72, -0.9]. Viewer-relative plane ranking/extent fitting remains future work.

