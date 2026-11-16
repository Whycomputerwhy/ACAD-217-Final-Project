import SwiftUI

@main
struct MergePrototypeApp: App {
    @State private var model = AppModel()
    @State private var immersionStyle: ImmersionStyle = .mixed

    var body: some Scene {
        WindowGroup(id: "launch") {
            ContentView()
                .environment(model)
        }
        .windowStyle(.plain)
        .defaultSize(width: 1, height: 1)

        ImmersiveSpace(id: AppModel.playSpaceID) {
            ImmersiveView()
                .environment(model)
        }
        .immersionStyle(selection: $immersionStyle, in: .mixed)
    }
}

