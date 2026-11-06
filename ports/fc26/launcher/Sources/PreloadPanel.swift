import AppKit
import SwiftUI

@MainActor
final class PreloadPanel {
    private var panel: NSPanel?
    private var content: NSHostingView<PreloadPanelView>?

    func show(_ preload: ShaderPreload) {
        if let content {
            content.rootView = PreloadPanelView(preload: preload)
            return
        }
        let content = NSHostingView(rootView: PreloadPanelView(preload: preload))
        let size = content.fittingSize
        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.contentView = content
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .statusBar
        panel.collectionBehavior = [
            .canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle,
        ]
        panel.hidesOnDeactivate = false
        panel.ignoresMouseEvents = true
        if let screen = NSScreen.main ?? NSScreen.screens.first {
            panel.setFrameOrigin(
                NSPoint(
                    x: screen.frame.midX - size.width / 2,
                    y: screen.frame.minY + screen.frame.height * 0.12))
        }
        panel.orderFrontRegardless()
        self.panel = panel
        self.content = content
    }

    func close() {
        panel?.orderOut(nil)
        panel = nil
        content = nil
    }
}

struct PreloadPanelView: View {
    let preload: ShaderPreload

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("EA SPORTS FC 26 Port").font(.headline)
            if preload.total > 0 {
                ProgressView(value: Double(preload.pipelines), total: Double(preload.total))
            } else {
                ProgressView().progressViewStyle(.linear)
            }
            Text(preload.summary + " The game starts when this finishes.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .frame(width: 380)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
    }
}
