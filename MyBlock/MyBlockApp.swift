import SwiftUI

@main
struct MyBlockApp: App {
    init() {
        // Before any view reads a font from Theme.
        FontRegistry.registerBundledFonts()
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .preferredColorScheme(.light)
                .tint(Theme.accent)
        }
    }
}

/// The app is a short linear flow, so screens are switched with plain state:
///   home -> session (record a start) -> review (watch, check frames) -> results
enum Route: Hashable {
    case home
    /// `autoStart` is used by "Try again": the countdown begins as soon as the camera is ready.
    case session(sessionID: UUID, autoStart: Bool)
    case review(UUID)
    case results(UUID)
}

struct RootView: View {
    @State private var route: Route = .home
    @AppStorage("didOnboard") private var didOnboard = false
    @ObservedObject private var store = RepStore.shared

    var body: some View {
        ZStack {
            Theme.background.ignoresSafeArea()
            switch route {
            case .home:
                HomeView(
                    onStart: { route = .session(sessionID: UUID(), autoStart: false) },
                    onOpen: { route = .review($0) }
                )
            case let .session(sessionID, autoStart):
                SessionView(
                    sessionID: sessionID,
                    autoStart: autoStart,
                    onFinished: { route = .review($0) },
                    onExit: { route = .home }
                )
                .id(route)
            case let .review(id):
                if store.rep(id) != nil {
                    ReviewView(
                        repID: id,
                        onResults: { route = .results($0) },
                        onTryAgain: { route = .session(sessionID: $0, autoStart: true) },
                        onHome: { route = .home }
                    )
                    .id(id)
                } else {
                    Color.clear.onAppear { route = .home }
                }
            case let .results(id):
                ResultsView(
                    repID: id,
                    onReview: { route = .review(id) },
                    onTryAgain: { route = .session(sessionID: $0, autoStart: true) },
                    onHome: { route = .home }
                )
                .id(id)
            }
        }
        #if DEBUG
        // Screenshot/debug helper: `-debugOpenRep <uuid> [-debugResults YES]` opens a saved rep.
        .onAppear {
            let defaults = UserDefaults.standard
            if let raw = defaults.string(forKey: "debugOpenRep"), let id = UUID(uuidString: raw) {
                route = defaults.bool(forKey: "debugResults") ? .results(id) : .review(id)
            }
        }
        #endif
        .fullScreenCover(isPresented: Binding(get: { !didOnboard }, set: { if !$0 { didOnboard = true } })) {
            OnboardingView { didOnboard = true }
        }
    }
}
