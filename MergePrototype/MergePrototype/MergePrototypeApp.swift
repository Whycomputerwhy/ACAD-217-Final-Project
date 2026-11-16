import SwiftUI

@main
struct MergePrototypeApp: App {
    @State private var model = AppModel()
    @State private var immersionStyle: ImmersionStyle = .mixed

    var body: some Scene {
        ImmersiveSpace(id: AppModel.playSpaceID) {
            ImmersiveView()
                .environment(model)
        }
        .immersionStyle(selection: $immersionStyle, in: .mixed)
    }
}

