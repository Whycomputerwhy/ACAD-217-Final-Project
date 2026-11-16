import SwiftUI

/// A 1 × 1 point bootstrap scene required by visionOS. It opens the immersive workspace and removes itself.
struct ContentView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openImmersiveSpace) private var openImmersiveSpace
    @Environment(\.dismissWindow) private var dismissWindow
    @State private var hasLaunched = false

    var body: some View {
        Color.clear
            .frame(width: 1, height: 1)
            .task {
                guard !hasLaunched else { return }
                hasLaunched = true
                let result = await openImmersiveSpace(id: AppModel.playSpaceID)
                if result == .opened {
                    model.isImmersive = true
                    dismissWindow(id: "launch")
                }
            }
    }
}

