import RealityKit
import SwiftUI

struct ImmersiveView: View {
    @Environment(AppModel.self) private var model
    @State private var fusion = FusionController()

    var body: some View {
        RealityView { content, attachments in
            fusion.configure(content: content, model: model)
            fusion.attachEditPalette(attachments.entity(for: "editPalette"))
        } update: { _, attachments in
            fusion.consumeCommands(model: model)
            fusion.attachEditPalette(attachments.entity(for: "editPalette"))
        }
        attachments: {
            Attachment(id: "editPalette") { EditPalette(model: model) }
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

private struct EditPalette: View {
    @Bindable var model: AppModel
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("EDIT").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            HStack { Button("Make White") { model.makeWhiteToken += 1 }; Button("Undo") { model.undoToken += 1 }; Button("Clear") { model.clearToken += 1 } }.buttonStyle(.bordered)
        }
        .padding(16).frame(width: 290).glassBackgroundEffect()
    }
}
