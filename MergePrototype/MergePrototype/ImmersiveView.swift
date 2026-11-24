import RealityKit
import SwiftUI

struct ImmersiveView: View {
    @Environment(AppModel.self) private var model
    @Binding var immersionStyle: ImmersionStyle
    @State private var fusion = FusionController()
    @GestureState private var isDragging = false

    var body: some View {
        RealityView { content, attachments in
            fusion.configure(content: content, model: model)
            attachPanels(attachments)
        } update: { _, attachments in
            fusion.consumeCommands(model: model)
            attachPanels(attachments)
        } attachments: {
            Attachment(id: "objectHeader") {
                Text("OBJECTS").font(.caption.weight(.semibold))
                    .padding(12).frame(width: 236).glassBackgroundEffect()
                    .allowsHitTesting(false)
            }
            ForEach(FusionController.availableAssets, id: \.self) { asset in
                Attachment(id: asset) {
                    CatalogCard(asset: asset).allowsHitTesting(false)
                }
            }
            Attachment(id: "editPalette") { EditPalette(model: model) }
        }
        .gesture(
            DragGesture(minimumDistance: 2)
                .targetedToEntity(where: .has(StudioInputTarget.self))
                .updating($isDragging) { _, state, _ in state = true }
                .onChanged { fusion.drag($0) }
                .onEnded { fusion.finishDrag($0) }
        )
        .onChange(of: isDragging) { _, active in
            // GestureState resets for cancellations too; onEnded alone does not.
            if !active { fusion.endInteraction() }
        }
        .onChange(of: model.fullScaleView, initial: true) { _, enabled in
            fusion.endInteraction()
            immersionStyle = enabled ? .full : .mixed
            fusion.setFullScale(enabled)
        }
        .onDisappear {
            fusion.stop()
            model.isImmersive = false
        }
    }

    private func attachPanels(_ attachments: RealityViewAttachments) {
        fusion.attachHeader(attachments.entity(for: "objectHeader"))
        fusion.attachEditPalette(attachments.entity(for: "editPalette"))
        for (index, asset) in FusionController.availableAssets.enumerated() {
            fusion.attachCatalogCard(attachments.entity(for: asset), asset: asset, index: index)
        }
    }
}

private struct CatalogCard: View {
    let asset: String

    var body: some View {
        VStack(spacing: 3) {
            Model3D(named: asset, bundle: .main) { model in
                model.resizable().aspectRatio(contentMode: .fit)
            } placeholder: {
                Color.clear
            }
            .frame(width: 92, height: 66)
            Text(asset.capitalized).font(.system(size: 12)).lineLimit(1)
        }
        .frame(width: 108, height: 96)
        .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
    }
}

private struct EditPalette: View {
    @Bindable var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("EDIT").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            Toggle("Full-scale view", isOn: $model.fullScaleView)
            Picker("HDRI", selection: $model.selectedHDRI) {
                ForEach(AppModel.HDRI.allCases) { hdri in Text(hdri.rawValue).tag(hdri) }
            }
            .pickerStyle(.segmented)
            HStack {
                Button("Make White") { model.makeWhiteToken += 1 }
                Button("Undo") { model.undoToken += 1 }
                Button("Clear") { model.clearToken += 1 }
            }.buttonStyle(.bordered)
        }
        .padding(16).frame(width: 290).glassBackgroundEffect()
    }
}
