import SwiftUI

@main
struct KestrelApp: App {
    @StateObject private var model = TunnelModel()
    @Environment(\.scenePhase) private var phase

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(model)
                .preferredColorScheme(.dark)
                .task { await model.load() }
                // a kestrel1: link opened from the Kestrel page sets this iPhone up
                .onOpenURL { url in
                    let code = url.absoluteString
                    guard let key = DeviceKey.parse(code) else {
                        model.error = DeviceKey.decode(code).failureMessage
                        return
                    }
                    Task { await model.install(key, raw: code) }
                }
                .onChange(of: phase) { phase in
                    if phase == .active { Task { await model.refreshReport() } }
                }
        }
    }
}

extension Result where Failure == SetupCodeError {
    var failureMessage: String? {
        if case .failure(let problem) = self { return problem.message }
        return nil
    }
}

struct RootView: View {
    @EnvironmentObject var model: TunnelModel

    var body: some View {
        ZStack {
            Ink.bg.ignoresSafeArea()
            if !model.loaded {
                ProgressView().tint(Ink.muted)
            } else if model.device == nil {
                WelcomeView()
                    .transition(.opacity)
            } else {
                HomeView()
                    .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.25), value: model.device?.name)
        .foregroundStyle(Ink.ink)
    }
}
