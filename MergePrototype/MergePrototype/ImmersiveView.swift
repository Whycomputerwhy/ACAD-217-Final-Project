import RealityKit
import SwiftUI

struct ImmersiveView: View {
    @Environment(AppModel.self) private var model
    @Binding var immersionStyle: ImmersionStyle
    @State private var fusion = FusionController()

    var body: some View {
        RealityView { content, attachments in
            fusion.configure(content: content, model: model)
            fusion.attachObjectPalette(attachments.entity(for: "objectPalette"))
            fusion.attachEditPalette(attachments.entity(for: "editPalette"))
        } update: { _, attachments in
            fusion.consumeCommands(model: model)
            fusion.attachObjectPalette(attachments.entity(for: "objectPalette"))
            fusion.attachEditPalette(attachments.entity(for: "editPalette"))
        }
        attachments: {
            Attachment(id: "objectPalette") { ObjectPalette() }
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
        .onChange(of: model.fullScaleView, initial: true) { _, isFullScale in
            immersionStyle = isFullScale ? .full : .mixed
            fusion.setFullScale(isFullScale)
        }
        .preferredSurroundingsEffect(model.fullScaleView ? .dark : nil)
    }
}

private struct ObjectPalette: View {
    @Environment(AppModel.self) private var model
    private static let assets = [
        ("apple", "Apple"), ("elephant", "Elephant"), ("crate", "Crate"),
        ("chair", "Chair"), ("table", "Table"), ("clock", "Clock"),
        ("candlestick", "Candle"), ("ukulele", "Ukulele"), ("eraser", "Eraser"), ("pen", "Pen")
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("OBJECTS").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            Text("Pinch and drag a model into the workspace")
                .font(.caption2).foregroundStyle(.secondary)
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 7) {
                ForEach(Array(Self.assets.enumerated()), id: \.element.0) { index, item in
                    let asset = item.0
                    let title = item.1
                    VStack(spacing: 2) {
                        Model3D(named: asset, bundle: .main) { model in
                            model.resizable().aspectRatio(contentMode: .fit)
                        } placeholder: {
                            ProgressView().controlSize(.mini)
                        }
                        .frame(width: 68, height: 54)
                        Text(title).font(.system(size: 9)).lineLimit(1)
                    }
                    .frame(width: 78, height: 76)
                    .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
                    .contentShape(RoundedRectangle(cornerRadius: 8))
                    .gesture(
                        SpatialEventGesture()
                            .onChanged { events in
                                for event in events where event.phase == .active {
                                    let point = event.location3D
                                    let location = SIMD3(Float(point.x), Float(point.y), Float(point.z))
                                    model.beginCatalogDrag(asset, index: index, location: location)
                                    model.updateCatalogDrag(location: location)
                                }
                            }
                            .onEnded { _ in model.endCatalogDrag() }
                    )
                }
            }
        }
        .padding(14).frame(width: 220).glassBackgroundEffect()
    }
}

private struct EditPalette: View {
    @Bindable var model: AppModel
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("EDIT").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            Toggle("Full-scale view", isOn: $model.fullScaleView)
            Picker("HDRI", selection: $model.selectedHDRI) {
                ForEach(AppModel.HDRI.allCases) { hdri in
                    Text(hdri.rawValue).tag(hdri)
                }
            }
            .pickerStyle(.segmented)
            HStack { Button("Make White") { model.makeWhiteToken += 1 }; Button("Undo") { model.undoToken += 1 }; Button("Clear") { model.clearToken += 1 } }.buttonStyle(.bordered)
        }
        .padding(16).frame(width: 290).glassBackgroundEffect()
    }
}
