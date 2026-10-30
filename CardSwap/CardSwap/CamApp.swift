import SwiftUI

@main
struct CamApp: App {
    @StateObject private var model = CameraModel()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            CameraScreen(model: model)
                .statusBarHidden()
                .preferredColorScheme(.dark)
                .onChange(of: scenePhase) { _, phase in
                    switch phase {
                    case .active:
                        model.start()
                    case .inactive, .background:
                        // Stopping on the way out also puts the torch out,
                        // which otherwise stays lit behind the app.
                        model.stop()
                    @unknown default:
                        break
                    }
                }
        }
    }
}
