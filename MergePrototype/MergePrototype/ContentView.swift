import SwiftUI

struct ContentView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openImmersiveSpace) private var openImmersiveSpace
    @Environment(\.dismissImmersiveSpace) private var dismissImmersiveSpace

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "cube.transparent")
                .font(.system(size: 34)).foregroundStyle(.mint)
            Text("MergePrototype").font(.title2.weight(.semibold))
            Button(model.isImmersive ? "Leave Workspace" : "Enter Workspace") {
                Task {
                    if model.isImmersive { await dismissImmersiveSpace(); model.isImmersive = false }
                    else { model.isImmersive = (await openImmersiveSpace(id: AppModel.playSpaceID) == .opened) }
                }
            }.buttonStyle(.borderedProminent)
            if model.isImmersive {
                Text(model.phase.rawValue).font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(24).frame(width: 280)
    }
}

