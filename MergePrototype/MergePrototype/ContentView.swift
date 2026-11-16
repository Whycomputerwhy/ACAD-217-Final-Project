import SwiftUI

struct ContentView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openImmersiveSpace) private var openImmersiveSpace
    @Environment(\.dismissImmersiveSpace) private var dismissImmersiveSpace

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Fusion Studio").font(.largeTitle.bold())
            Text("A live Boolean-union study for spatial composition")
                .font(.title3).foregroundStyle(.secondary)
            Divider()
            Text(model.phase.rawValue).font(.headline)
                .foregroundStyle(model.phase == .fusing ? .mint : .primary)
            HStack(spacing: 12) {
                Button(model.isImmersive ? "Leave Studio" : "Enter Studio") {
                    Task {
                        if model.isImmersive { await dismissImmersiveSpace(); model.isImmersive = false }
                        else { model.isImmersive = (await openImmersiveSpace(id: AppModel.playSpaceID) == .opened) }
                    }
                }.buttonStyle(.borderedProminent)
                Button("Reset") { model.resetToken += 1 }.disabled(!model.isImmersive)
            }
            Text("Use the right-side spatial palette to drag out forms and edit the composition.")
                .font(.footnote).foregroundStyle(.secondary)
            Text("\(model.fusionCount) active fusion connection\(model.fusionCount == 1 ? "" : "s")").font(.footnote).foregroundStyle(.secondary)
            Text("The square work surface automatically settles onto a detected table or floor. The mint field marks the live visual union; it is intentionally a fast preview, not exported geometry.")
                .font(.footnote).foregroundStyle(.tertiary).fixedSize(horizontal: false, vertical: true)
        }
        .padding(30).frame(width: 560)
    }
}

