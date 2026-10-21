import SwiftData
import SwiftUI

@main
struct JanekApp: App {
    @Environment(\.scenePhase) private var scenePhase
    @State private var controller = AssistantController.shared

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(controller)
                .environment(AppSettings.shared)
                .task { await controller.bootstrap() }
                .onOpenURL { url in
                    // janek://listen – uruchomienie nasłuchu z widżetu/skrótu.
                    if url.host == "listen" { controller.startListeningManually() }
                }
        }
        .modelContainer(NotesDatabase.container)
        .onChange(of: scenePhase) { _, phase in
            controller.scenePhaseChanged(phase)
        }
    }
}
