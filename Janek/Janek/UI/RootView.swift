import SwiftUI

struct RootView: View {
    @Environment(AssistantController.self) private var controller
    @Environment(AppSettings.self) private var settings
    @State private var showOnboarding = false

    var body: some View {
        @Bindable var controller = controller
        NavigationStack {
            AssistantView()
        }
        .onAppear { showOnboarding = !settings.hasCompletedOnboarding || (!KeychainStore.hasAPIKey && settings.aiMode != .local) }
        .fullScreenCover(isPresented: $showOnboarding) {
            OnboardingView {
                showOnboarding = false
                Task { await controller.bootstrap() }
            }
        }
        .sheet(item: $controller.presentedSheet) { sheet in
            switch sheet {
            case .camera:
                CameraView().ignoresSafeArea()
            case .messageComposer(let recipients, let body):
                MessageComposerView(recipients: recipients, body: body).ignoresSafeArea()
            case .document(let url):
                DocumentPreview(url: url).ignoresSafeArea()
            }
        }
    }
}
