import SwiftUI

@main
struct KestrelApp: App {
    @StateObject private var model = TunnelModel()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(model)
                .preferredColorScheme(.dark)
                .task { await model.load() }
        }
    }
}

enum Ink {
    static let bg = Color.black
    static let raise = Color(white: 0.07)
    static let line = Color(white: 0.13)
    static let ink = Color(white: 0.96)
    static let muted = Color(white: 0.56)
    static let faint = Color(white: 0.36)
    static let accent = Color(red: 0.878, green: 0.482, blue: 0.271) // kestrel rufous
    static let danger = Color(red: 1.0, green: 0.42, blue: 0.37)
}

extension Font {
    static func geist(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .custom("Geist", size: size).weight(weight)
    }
    static func geistMono(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .custom("Geist Mono", size: size).weight(weight)
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
