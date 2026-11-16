import RealityKit
import SwiftUI

struct ImmersiveView: View {
    @Environment(AppModel.self) private var model
    @State private var fusion = FusionController()

    var body: some View {
        RealityView { content, attachments in
            fusion.configure(content: content, model: model)
            fusion.attachPalette(attachments.entity(for: "workspacePalette"))
        } update: { _, attachments in
            fusion.consumeCommands(model: model)
            fusion.attachPalette(attachments.entity(for: "workspacePalette"))
        }
        attachments: {
            Attachment(id: "workspacePalette") { WorkspacePalette(model: model) }
        }
        .gesture(
            DragGesture()
                .targetedToAnyEntity()
                .onChanged { fusion.drag($0) }
                .onEnded { fusion.finishDrag($0, model: model) }
        )
        .onDisappear {
            model.isImmersive = false
        }
    }
}

private struct WorkspacePalette: View {
    @Bindable var model: AppModel
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("OBJECTS").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            Text("Drag a 3D tile below into the workspace").font(.caption2).foregroundStyle(.secondary)
            Divider()
            HStack(spacing: 8) {
                Button("Apple") { model.addAppleToken += 1 }
                Button("Elephant") { model.addElephantToken += 1 }
                Button("Crate") { model.addCrateToken += 1 }
            }.buttonStyle(.bordered)
            Divider()
            Text("EDIT").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            Toggle("Interior lining", isOn: $model.inspectionEnabled)
            HStack { Button("Undo") { model.undoToken += 1 }; Button("Clear") { model.clearToken += 1 } }.buttonStyle(.bordered)
        }
        .padding(16).frame(width: 290).glassBackgroundEffect()
    }
}
