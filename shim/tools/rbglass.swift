// Developer tool: SwiftUI Liquid Glass drawn by RenderBox in-process (inside a drawingGroup), the path Spotlight
// uses for its glass: displacementMap_v1 / distanceGradient_v1 / glassHighlight_v1 ... are SwiftUI shaders linked
// into RenderBox's custom_effect / primitive_custom pipelines as visible functions.
// Usage: DYLD_INSERT_LIBRARIES=build/libTSMetalInject.dylib [RBGLASS_SECONDS=n] tools/rbglass   (quits after n s, 6)
// (no positional arguments: AppKit takes them as files to open and SwiftUI then opens no window)
// Its translations are recorded as seeds of system.mslbundle (tools/mslbundle).
import SwiftUI
import AppKit

struct GlassScene: View {
    var body: some View {
        ZStack {
            LinearGradient(colors: [.red, .blue, .green, .yellow], startPoint: .topLeading, endPoint: .bottomTrailing)
            GlassEffectContainer(spacing: 18) {
                VStack(spacing: 16) {
                    Text("Glass").font(.largeTitle).padding(26).glassEffect()
                    HStack(spacing: 14) {
                        Text("Regular").padding(16).glassEffect(.regular, in: .rect(cornerRadius: 16))
                        Text("Clear").padding(16).glassEffect(.clear)
                        Text("Interactive").padding(16).glassEffect(.regular.interactive())
                    }
                    HStack { Circle().fill(.white).frame(width: 36, height: 36); Text("Tint") }
                        .padding(12).glassEffect(.regular.tint(.orange))
                    Capsule().fill(.clear).frame(width: 320, height: 44).glassEffect(.regular.tint(.purple).interactive(), in: .capsule)
                }
            }
        }
        .frame(width: 480, height: 340)
        .drawingGroup()
    }
}

@main
struct RBGlass: App {
    init() {
        let seconds = Double(ProcessInfo.processInfo.environment["RBGLASS_SECONDS"] ?? "") ?? 6
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { NSApp.terminate(nil) }
    }
    var body: some Scene { WindowGroup { GlassScene() } }
}
