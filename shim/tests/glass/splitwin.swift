// SwiftUI NavigationSplitView (like System Settings) in an NSWindow for N seconds (argv[1]); prints its screen rect. NSV_TREE=1: view tree.
import AppKit
import SwiftUI
struct Split: View {
    var body: some View {
        NavigationSplitView {
            List(["Wi-Fi", "Bluetooth", "Rete", "Generali"], id: \.self) { Text($0) }
        } detail: { Text("Dettaglio").frame(maxWidth: .infinity, maxHeight: .infinity) }
    }
}
let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 840, height: 420), styleMask: [.titled, .fullSizeContentView], backing: .buffered, defer: false)
w.contentViewController = NSHostingController(rootView: Split())
w.setContentSize(NSSize(width: 840, height: 420))
w.center()
w.orderFrontRegardless()
let f = w.frame, s = NSScreen.main!.frame
print("rect \(Int(f.origin.x)),\(Int(s.height - f.origin.y - f.size.height)),\(Int(f.size.width)),\(Int(f.size.height))")
fflush(stdout)
if ProcessInfo.processInfo.environment["NSV_TREE"] != nil {
    DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
        func dump(_ v: NSView, _ d: Int) {
            print(String(repeating: "  ", count: d) + "\(type(of: v)) \(Int(v.frame.origin.x)),\(Int(v.frame.origin.y)) \(Int(v.frame.width))x\(Int(v.frame.height))")
            for c in v.subviews { dump(c, d + 1) }
        }
        dump(w.contentView!.superview!, 0)
        fflush(stdout)
    }
}
DispatchQueue.main.asyncAfter(deadline: .now() + (Double(CommandLine.arguments.dropFirst().first ?? "5") ?? 5)) { exit(0) }
app.run()
