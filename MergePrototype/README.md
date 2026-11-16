# MergePrototype — AI / developer handoff

Last updated: 2026-11-16

## Purpose

This is a visionOS spatial-composition prototype. A person assembles preset USDZ forms on a square workbench and receives a **fast visual indication** that nearby forms will merge. The intended future experience is a real-time visual Boolean union with a hollow, single-material interior and a separately generated export mesh.

Do not describe the current mint effect as a true Boolean operation: it is intentionally only a visual preview for interaction testing.

## Current interaction

1. The window opens the mixed immersive space with **Enter Studio**.
2. `PlaneDetectionProvider` looks for a horizontal table or floor. Once found, the square workbench follows that plane. A fixed position in front of the viewer is used as a fallback while sensing is unavailable or pending.
3. The person can pinch-drag source objects on the workbench.
4. Three small 3D palette tiles sit on the right side of the workbench. Dragging one creates a new full-size instance at the dragged position.
5. When any pair of source-object origins comes within 0.34 m, a translucent mint sphere appears as the **live fusion preview**.
6. The right-side panel also offers button equivalents for adding presets, plus Interior lining, Undo, and Clear.
7. Turning on **Interior lining** changes the preview field to purple. This only communicates the future unified inner-shell material; it does not cut open or generate an actual hollow object.

## Project map

```text
MergePrototype/
├── MergePrototype.xcodeproj/        Xcode project; scheme is MergePrototype
├── MergePrototype/
│   ├── MergePrototypeApp.swift       App + ImmersiveSpace declaration
│   ├── ContentView.swift             Launch window; enter/reset controls
│   ├── ImmersiveView.swift           RealityView, drag gesture, right-side SwiftUI attachment
│   ├── AppModel.swift                Observable UI state and command tokens
│   ├── FusionController.swift        Main runtime: workbench, plane tracking, palette, object spawning, preview
│   ├── Info.plist                    Includes World Sensing permission copy
│   └── Resources/
│       ├── apple.usdz
│       ├── elephant.usdz
│       └── crate.usdz
├── Packages/RealityKitContent/       Default Reality Composer Pro package retained from the original project
└── README.md                         This handoff document
```

The visual layout reference supplied by the user lives beside this project, not inside it:

```text
../layout.realitycomposerpro/
```

It originally had a circular base and a side menu. The runtime implementation now replaces that base with a square programmatic RealityKit workbench so it can attach to a detected physical surface.

## Source-of-truth files

| Need to change | File | Notes |
| --- | --- | --- |
| Workbench placement or plane selection | `FusionController.swift` | `startPlaneDetection()` accepts `.table` and `.floor`; `workbench` is the anchor for all spatial content. |
| 3D object palette / drag-out behavior | `FusionController.swift` | `makePaletteTile`, `drag`, `addAsset`, and `paletteKind`. Do not add a tile without putting its USDZ in `Resources`. |
| Right-side UI controls | `ImmersiveView.swift` | `WorkspacePalette` is a `RealityView` attachment, positioned at `x = 0.78` relative to the workbench. |
| Buttons / state events | `AppModel.swift` and `ContentView.swift` | The model uses incrementing tokens so RealityKit can consume UI commands reliably. |
| Fusion visual | `FusionController.swift` | `refreshPreview` decides which objects connect; `makeFusionField` creates the temporary mint/purple preview geometry. |

## Important technical constraints

- The input assets are controlled application resources, not user imports. This is intentional and should remain true for the prototype.
- A source object is loaded asynchronously from the app bundle, normalized to a target size, given collision shapes, and made an `InputTargetComponent`.
- Drag handling walks up an entity's parent chain. Do not simplify this to inspect only the event entity: USDZ collision targets may be a child entity rather than the named root.
- Plane sensing requires `NSWorldSensingUsageDescription` and only behaves fully on a Vision Pro. The simulator uses the fallback workbench position.
- The project compiles with the visionOS SDK, but real-world placement and spatial dragging need device validation.
- `TossGameController.swift` is leftover, excluded from the target, and unrelated to MergePrototype. Do not reactivate it.

## What is deliberately not implemented

- No mesh Boolean union.
- No signed-distance field / raymarch renderer.
- No hollow shell, thickness setting, interior camera, collision merge, mesh cleanup, export, or undo history beyond deleting the most recently added source.
- No material transfer from source assets to a generated union surface.

## Recommended next work

1. **Validate on device.** Tune workbench dimensions, right-panel scale/position, initial source scale, and the 0.34 m connection threshold using real hand interaction.
2. **Improve the preview.** Replace `makeFusionField` with a Metal SDF renderer. Preserve the current controller interface and use the existing source transforms as inputs.
3. **Separate preview from export.** On an explicit Export action, generate a watertight shell with a fixed thickness; retain source materials on the exterior and one shared material for interior faces.
4. **Make edit controls honest.** Add object selection, delete selected, transform/rotation controls, and a real action stack before calling Undo a production feature.

## Build

1. Open `MergePrototype.xcodeproj` in Xcode.
2. Select an Apple Vision Pro target or simulator.
3. Set a signing team if Xcode requires one.
4. Run, open the studio, and grant World Sensing permission on device.

The project was compiled successfully with the visionOS SDK after the current layout/plane-detection update.

